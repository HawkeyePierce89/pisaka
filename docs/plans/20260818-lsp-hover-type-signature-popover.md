# LSP hover: type/signature popover under the mouse in the macOS editor

## Overview

Add `textDocument/hover` to the LSP stack and a small, non-interactive popover
in the macOS editor that shows the server's answer when the pointer rests over
an identifier. Everything that decides anything lives in `PisakaCore` and is
unit-tested: the protocol payload shapes, the markup→segments normalization,
the truncation cap, the dwell constant, the capability gate and the
request-superseding rules. The macOS layer contributes exactly two things —
mouse tracking on the editor's text view, and a borderless panel that draws the
segments.

Two design choices shape the view layer:

- **The popover is unreachable by the pointer.** The panel sets
  `ignoresMouseEvents = true`, so it is a purely visual overlay: clicks,
  ⌘-clicks, drag-selection and the context menu pass straight through it to the
  text view below, and a pointer that moves "onto" the popover is in fact still
  over the code and simply updates or dismisses the hover. This is what makes
  the ticket's "chrome, not a code surface" literally true
  (`ZoomSurface.swift`'s "unreachable ≡ chrome" rule), so nothing joins
  `ZoomSourceGatingTests.zoomSurfaceDeclarers`, and it is the cheapest possible
  guarantee that hover cannot interfere with typing or focus.
- **Long content truncates rather than scrolls.** A scrollable popover would
  require the pointer to enter it, which contradicts the point above and would
  make the panel a zoom surface, a focus target and a hit-test obstacle. So
  Core caps the content by line count and marks it truncated; the panel draws
  an ellipsis line.

There is no tree-sitter fallback and no new user setting: no server, no
capability, an empty answer or a failure all mean "no popover", silently.

## Context

- Files involved:
  - Core, modified: `Sources/PisakaCore/LSPProtocolTypes.swift`,
    `LSPSession.swift`, `LSPIntelligenceProvider.swift`,
    `RoutingIntelligenceProvider.swift`, `CodeIntelligence.swift`
  - Core, new: `Sources/PisakaCore/HoverContent.swift`
  - App (macOS), new: `Sources/Pisaka/HoverController.swift`,
    `Sources/Pisaka/HoverPanel.swift`
  - App (macOS), modified: `Sources/Pisaka/CodeEditorView.swift`,
    `Sources/Pisaka/ContentView.swift`
  - Tests, new: `Tests/PisakaCoreTests/HoverContentTests.swift`
  - Tests, modified: `LSPProtocolTypesTests.swift`, `LSPSessionTests.swift`,
    `LSPIntelligenceProviderTests.swift`,
    `RoutingIntelligenceProviderTests.swift`, `LSPSourceGatingTests.swift`,
    `ZoomSourceGatingTests.swift`
  - Docs: `docs/architecture/core-lsp.md`, `docs/architecture/app-editor.md`,
    `CLAUDE.md`, `README.md`, `docs/FEATURES.md`
- Related patterns:
  - `LSPIntelligenceProvider.definitions(for:)` — the whole request shape: the
    D2 empty-buffer guard, `workspace.prepare`, `LSPPositionMap`, the
    `workspace.stillHolds(prepared)` staleness gate, "no answer is better than
    a guessed one".
  - `RoutingIntelligenceProvider` — `canServe` first, then `withBudget`.
  - `CompletionController` — the debounce + monotonic generation-token idiom
    for a view-side async request (`BracketHighlightController` is the same
    shape).
  - `DefinitionPicker` — the precedent for a thin, untested AppKit surface
    anchored to a text range.
  - The repository-file gating suites: a new `LSP*`-prefixed *or* layer-owned
    Core file must be added to `LSPSourceGatingTests`' lists; new macOS app
    files in this layer must open with `#if os(macOS)`.
- Dependencies: none new. No network, no new package, no new bundled resource.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core layers;
  the macOS view layer stays untested by convention, with its one invisible
  rule pinned by a source-gating assertion.
- Complete each task fully before moving to the next; `swift test` must be
  green at the end of every task.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- No new `Fixtures/LSP/` files: that directory's README claims recorded
  provenance from a real `sourcekit-lsp` run, and the hover shapes being
  covered are a *spec* matter, not a server-behaviour one. Payload-shape
  coverage therefore lives as inline JSON literals in the tests.

## Implementation Steps

### Task 1: Speak `textDocument/hover`

**Files:**
- Modify: `Sources/PisakaCore/LSPProtocolTypes.swift`,
  `Sources/PisakaCore/LSPSession.swift`
- Modify: `Tests/PisakaCoreTests/LSPProtocolTypesTests.swift`,
  `Tests/PisakaCoreTests/LSPSessionTests.swift`

- [x] Teach the protocol layer the request and every legal answer: add
      `LSPMethod.hover`; decode `Hover` in all its spellings — `null`, a bare
      `MarkedString` (plain string **or** `{language, value}`), an array mixing
      both, and a `MarkupContent` (`{kind: "markdown"|"plaintext", value}`) —
      plus the optional `range`. Follow the file's stated rule: decode
      leniently (an unknown `kind` degrades to plaintext, a malformed element
      is dropped rather than failing the whole decode), encode exactly. The
      decoded result must preserve element order and each element's declared
      language, because that is what the renderer distinguishes code from prose
      by.
- [x] Advertise the capability the way the closed capability tree is written:
      `textDocument.hover` with `dynamicRegistration: false` and
      `contentFormat: ["markdown", "plaintext"]`. Read the server's side into
      `LSPServerCapabilities.supportsHover`, using the same `boolean | Options`
      collapse the two existing providers use.
- [x] Give `LSPSession` a `hover(_:)` exchange with its own entry in `Budgets`
      (1.5 s — hover is interactive and nobody is waiting deliberately, so it
      is completion's budget, not definition's), decoding through the existing
      `decode(_:as:method:)` so a missing `result` and an explicit `null`
      remain the same answer.
- [x] Write tests: every payload shape above decodes to what the renderer
      expects, including `null`, an empty array and an empty string; the
      encoded client capability tree contains the new hover node (update the
      existing capability-tree assertion rather than weakening it); a scripted
      transport proves `hover` is sent with the right params, times out on its
      own budget without disturbing other pending requests, and
      `$/cancelRequest`s when the caller's task is cancelled.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Normalize hover markup into renderable segments

**Files:**
- Create: `Sources/PisakaCore/HoverContent.swift`
- Create: `Tests/PisakaCoreTests/HoverContentTests.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [x] Introduce the value types the view renders and nothing more: an ordered
      list of segments, each either code (with the language the server named,
      when it named one) or prose, plus a truncation flag. This type must know
      nothing about LSP — it is what a renderer consumes — while the
      *construction* from the decoded hover payload lives with it and is the
      one place markup is interpreted.
- [x] Implement the normalization as pure logic: fenced code blocks become code
      segments (the info string becomes the language); a `MarkedString` with a
      language is a code segment whole; prose is degraded rather than shown raw
      — inline code loses its backticks, emphasis/strong markers are dropped,
      headings lose their `#`, list bullets keep a bullet, links and images
      keep their text/alt and lose the URL, horizontal rules and stray HTML
      tags are dropped; runs of blank lines collapse; leading/trailing
      whitespace goes.
- [x] Make emptiness a first-class answer: content that normalizes to nothing,
      or to whitespace only, is `nil` — there is no such thing as an empty
      popover. Multiple `MarkedString` elements stay separate segments in the
      order the server sent them.
- [x] Own the two constants the feature is specified by, here rather than in
      the view: the dwell delay (0.35 s — one constant, no scattered literals)
      and the maximum rendered line count, with a pure `truncated(...)` that
      caps the segments and reports that it did.
- [x] Add the new file to `LSPSourceGatingTests`' Core prefix sweep and its
      expected-file list, the way `CompletionEditPlan` and
      `RoutingIntelligenceProvider` are listed — it is this layer's Core
      surface even without an `LSP` prefix, and the Foundation-only rule must
      cover it.
- [x] Write tests for every rule above, each degraded construct, the
      empty/whitespace-only cases, order preservation, and truncation (both
      under and over the cap).
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Ask through the seam, answer only when certain

**Files:**
- Modify: `Sources/PisakaCore/CodeIntelligence.swift`,
  `Sources/PisakaCore/LSPIntelligenceProvider.swift`,
  `Sources/PisakaCore/RoutingIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`,
  `Tests/PisakaCoreTests/RoutingIntelligenceProviderTests.swift`

- [x] Add the third question to `CodeIntelligenceProviding`: a hover request
      (file URL, UTF-16 offset, the live buffer) answering optional hover
      content plus the buffer range the answer covers. Default it to `nil` in
      the protocol extension, exactly as `resolveEdits` is defaulted — so the
      tree-sitter provider and both iOS surfaces are untouched and no existing
      call site changes. Document that the range is what a caller uses to
      decide the pointer is still over the same thing.
- [x] Implement it on `LSPIntelligenceProvider` by mirroring
      `definitions(for:)` step for step: D2's empty-buffer guard, language from
      the file name, `workspace.prepare` (so the live buffer reaches the server
      before the question), position via `LSPPositionMap`, the
      `stillHolds(prepared)` gate before the answer is read, and the server
      range mapped back to buffer coordinates. Ask nothing at all when the
      session's capabilities do not advertise hover. Every uncertainty —
      including a server answering content that normalizes to nothing — is
      `nil`.
- [x] Route it in `RoutingIntelligenceProvider`: `canServe` first (so a
      language with no server costs a function call), then the same
      whole-attempt `withBudget` race the other two use, with a hover budget
      beside them. **No fallback**: the wrapped provider is never consulted,
      because tree-sitter knows no types — and say so in the doc comment, since
      every other method here does fall through.
- [x] Write tests: a scripted server answering each payload shape produces the
      expected content and range; a server that does not advertise hover is
      never sent the request; a superseded/stale document (`stillHolds` false)
      answers `nil` and presents nothing; an empty or whitespace-only answer is
      `nil`; a language with no server never enters the stack; a timeout
      answers `nil` silently; and — the acceptance criterion — four failed
      launches for one `(server, root)` driven entirely by hover requests
      retire that key, after which hover asks nothing more.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: The pointer, the dwell, and the panel (macOS)

**Files:**
- Create: `Sources/Pisaka/HoverController.swift`,
  `Sources/Pisaka/HoverPanel.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`

- [ ] Track the pointer over the editor's text view with a tracking area scoped
      to the visible rect and the key window, and resolve the character
      actually *under* the pointer — not the nearest insertion point, which
      would answer for the last character of a line when the pointer is past
      its end. Ask only when that character belongs to an identifier per
      `IdentifierScanner`, which is also what gives a stable anchor range
      before the server names one.
- [ ] Add a hover controller in the `CompletionController` mould: one
      cancellable dwell task, one monotonic generation token captured
      synchronously before the hop, one panel. A newer pointer position
      supersedes an older request; an answer whose token is stale is dropped
      and never shown. Re-asking is suppressed while the pointer stays inside
      the range the current answer covers.
- [ ] Dismiss on everything the ticket lists: the pointer leaving the anchor
      range or the text view, a scroll (reuse the clip view's bounds-change
      observation the minimap already installs), any text edit, a selection
      change, a tab or file switch, the window resigning key, and teardown.
      Dismissal must be idempotent and must survive a dismissal racing an
      in-flight answer.
- [ ] Build the panel as a borderless, non-activating `NSPanel` that never
      becomes key and sets `ignoresMouseEvents = true`, positioned near the
      anchor range and flipped to stay on screen. Render code segments in the
      editor's monospaced font at `SettingsStore.fontSize` and prose in the
      interface font from `InterfaceMetrics` (passed into `CodeEditorView` as a
      plain value beside `fontSize`, following that property's precedent —
      never by naming the raw interface scale). Cap the width, cap the height
      via Core's line cap, and draw the truncation marker when Core says the
      content was cut.
- [ ] Confirm by construction that nothing here fights the zoom controller:
      hover uses tracking-area mouse-moved events, the zoom monitor takes only
      scroll and pinch, and the panel is not a zoom surface because the pointer
      cannot reach it.
- [ ] Write tests: extend `ZoomSourceGatingTests` with an assertion (over
      comment- and literal-stripped source, like its siblings) that the hover
      panel disables mouse events and declares no zoom surface — the rule that
      keeps it chrome, which nothing else can see; and confirm the existing
      zoom and LSP gating suites still pass unchanged by set equality.
- [ ] Run `swift test` — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [ ] `swift test` — the full suite, green.
- [ ] `xcodegen generate` if `project.yml` changed (it should not), then
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build` — the same destination `ci.yml` gates on
      (device arch, covers libgit2 linking, needs no installed simulator); the
      iOS build must be untouched by this feature (no iOS UI, Core stays
      platform-agnostic).
- [ ] Confirm the gating suites specifically: LSP platform split intact (no
      `Process` outside the transport), the zoom rules by set equality, the
      Sparkle split unaffected.

### Task 6: Update documentation

- [ ] `docs/architecture/core-lsp.md`: new decisions numbered from D25 —
      hover's payload normalization and its "empty is no answer" rule; hover
      has no tree-sitter fallback and why; the popover is
      unreachable-by-pointer chrome and truncates rather than scrolls. Add the
      file entries for the new Core surface and the new capability/budget.
- [ ] `docs/architecture/app-editor.md`: full entries for the hover controller
      and the panel — the dwell constant's home, the generation-token rule, the
      complete dismissal set, and the pass-through panel's guarantees.
- [ ] `CLAUDE.md`: one index line per new file, in the matching sections; no
      per-file essays.
- [ ] `README.md` and `docs/FEATURES.md`: the user-facing line — hovering a
      symbol shows its type/signature where a language server is available,
      macOS only.
