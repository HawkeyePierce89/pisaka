# PisakaCore — the LSP client (phase 2a: Swift via sourcekit-lsp)

Design documentation for the Language Server Protocol client that sits behind the
existing `CodeIntelligenceProviding` seam. Each entry records a file's contract,
invariants and the reasoning behind non-obvious decisions — read the relevant
entry before modifying that file, and update it when behavior changes.

**What this layer is.** A hand-rolled LSP client, Foundation-only and fully
unit-tested, that answers Go to Definition and completion for a Swift file from
`sourcekit-lsp` instead of from the tree-sitter symbol index. Everything else —
every other language, and every failure mode — keeps the index's answers,
silently and per request. No dependency ships with it: JSON-RPC is written here,
so nothing new enters the bundle and no pin or license changes.

**What phase 2b added, and where it is documented.** The client below is
unchanged except for one method — `LSPWorkspace.updateRegistry(_:)` (D16) — and
that one exists because 2b lets the app *provision* servers for itself:
`typescript-language-server` and `pyright`, downloaded on consent, verified
against a pinned SHA-256 and installed under Application Support, become
`.executable(path:)` registry entries the moment they land. All of that — the
manifest, the digest, the install engine, the consent rules, the two macOS-gated
seams and the Preferences surface — lives in
`docs/architecture/core-provisioning.md`, with decisions D11–D16. Every rule
below still holds for those servers: routing is per request, fallback to
tree-sitter is silent, and a language whose server is absent, declined or failed
is indistinguishable from one that never had a server at all.

**What the Go language work added, and why it is here rather than there.** Go
gets semantic intelligence on macOS through **gopls**, which cannot use 2b's
artifact path at all: gopls ships no official prebuilt binaries, so there is no
URL to pin, no digest to verify and nothing to unpack. It is *discovered* if the
user already has it, and otherwise built once — on consent — by the user's own Go
toolchain, into this app's own install root. That makes it a second **registry
contributor** rather than a second provisioning layer, and it lives in this
document, under decisions D17–D20, with entries for `LSPGoToolchain.swift` and
`LSPGoplsProvisioning.swift` at the end of the file list.

**What the Rust language work added, and why it is here too.** Rust gets semantic
intelligence on macOS through **rust-analyzer**, and it is the *hybrid* of the two
stories above rather than a third one: it is **discovered** if the user already
has it (rustup puts one in `~/.cargo/bin`, which is how nearly everyone has Rust),
and otherwise **downloaded** — unlike gopls, it publishes official prebuilt macOS
binaries, so there is a URL to pin, a digest to verify and something to unpack. It
therefore reuses 2b's engine, its pinned-component machinery and both of its seams
while keeping gopls's *shape*: a toolchain gate, a discovered-copy state, and a
Settings row 2b's cannot express. That makes it a **third registry contributor**,
documented here under decisions D21–D24 with entries for `LSPRustToolchain.swift`
and `LSPRustProvisioning.swift` at the end of the file list; the bytes half — the
`.gzip` archive format, the executable-bit gate, the manifest component and the
by-hand pin procedure — lives in `core-provisioning.md` where the rest of the
bytes are.

**What hover added, and why it is a third question rather than a third
provider.** Resting the pointer on an identifier in the macOS editor asks
`textDocument/hover` and draws the answer in a small popover. It is documented
here under decisions D25–D26, with an entry for `HoverContent.swift` beside
`CompletionEditPlan`'s, because it changes nothing about *who* answers: the same
sessions, the same workspace, the same registry, one more method on the seam. Two
things about it are unlike everything else in this document and are the reason it
has decisions of its own. **It has no tree-sitter fallback** — the index knows
names and locations, not types, so there is nothing to fall through to and no
server means no popover (D25). And **it normalizes markup**, which no other
answer here does: a hover reply is prose and code mixed in one string, so
`HoverContent` is the one place LSP's markup is interpreted, and content that
normalizes to nothing is `nil` rather than an empty popover. The view half — the
dwell, the tracking area and the pass-through panel — is macOS-only and lives in
`docs/architecture/app-editor.md`.

**What diagnostics added, and why it is a channel rather than a fourth question.**
Everything above this paragraph is *asked*: a request goes out because a keystroke,
a ⌘-click or a resting pointer wanted something now. `textDocument/publishDiagnostics`
is the one thing servers say unasked — errors and warnings pushed whenever they
re-diagnose a document they hold — and surfacing it (squiggly underlines in the
editor, severity markers in the gutter, a Problems panel in the bottom dock) needed
three structural additions rather than one more seam method. `LSPSession` had to stop
discarding server-initiated notifications, so they travel out on a stream with one
consumer (D29); D2's request-driven sync never re-diagnoses anything, so every open
buffer of a served language is flushed on a 400 ms debounce beside the symbol index's
own (D30); and a push describes text the buffer may have moved past, so it is mapped
against what the *server was told*, gated on version and revision, shifted across
each edit and dropped where the edit touched (D31–D32). Every teardown path clears
what its server reported (D33), and hover carries the messages so there is no second
popover surface (D34). Four Core files carry all of it — `Diagnostic.swift`,
`DiagnosticShift.swift`, `DiagnosticStore.swift` and `DiagnosticsModel.swift`, with
entries in their own section below — plus wire types in `LSPProtocolTypes.swift`, the
stream in `LSPSession.swift` and routing/clears in `LSPWorkspace.swift`; the app half
(the debounced sync controller, the squiggle/marker/panel surfaces) is documented in
`app-editor.md`, `app-editor-overlays.md` and `app-window.md`. There is no setting,
no consent surface and no iOS UI: diagnostics are what a registered server already
computes for a document it already holds, so absence of a server remains the one way
to have none.

**What rename and find usages added, and why one of them is a writer.** Two
commands sit on everything above: **Find Usages** (⌃⌘U) lists every place the
identifier under the caret is used, in a bottom-dock panel beside Problems, and
**Rename** (⌃⌘R) renames the symbol project-wide through the server's
`WorkspaceEdit`. They ask two more requests — `textDocument/references` and
`textDocument/rename` — read two more capability fields, and take **two budgets,
not one**. `references` gets a definition's three seconds (a command somebody
typed a shortcut for, not a pointer that stopped moving), because its expiry is
free: the model walks the project textually instead and the panel says so. Rename
gets twenty, because its expiry is not free — it has no second answer of any kind,
it arrives *after* the user has filled in a modal dialog, and a workspace rename
type-checks the reverse dependency graph where `references` reads an index. The
two are the same act asked two ways, but only one of them can fail invisibly. Everything else about them is new *policy* rather
than new plumbing, and it is written down as D35–D37. **Rename has no fallback of
any kind** (D35): hover's rule applied to the one question in this layer that
leads to a write, because the only non-semantic rename available is a textual
replace, which is indistinguishable from a correct one until it silently rewrites
a same-spelled symbol in a file nobody opened. **Find usages does have a second
answer, and it is not this layer's** (D36): the seam's `references` is
LSP-or-nothing, and the whole-word scan that answers when it says nothing belongs
to `FindUsagesModel`, because it costs a walk of the project and nothing in the
provider chain may walk a project. And **the document version a `WorkspaceEdit`
carries is decoded and never compared** (D37) — every range is verified against
the exact text it was computed over, which is the stronger check and the one that
also holds for a server that sends no version. The pure edit-plan half is
`RenameEditPlan.swift`, entered below beside `CompletionEditPlan`; the rows, the
panel model and the textual scanner are code-intelligence types and live in
`core-intelligence.md`; the app half — the menu items, the editor's context menu,
the name dialog and the seventh writer bracket — is in `app-editor.md`,
`app-window.md` and `app-shell.md`, with the "Before Rename" captures in
`core-local-history.md`.

**Where the platform boundary is.** All of it is in `PisakaCore` except one
thing: the `Process` and its three pipes, which live macOS-gated in
`Sources/Pisaka/LSPProcessTransport.swift` behind the `LSPTransport` protocol.
That is exactly the `GitServicing`/`GitCLIService` split, for the same reason —
framing, correlation, budgets, position mapping, restart policy and ranking all
stay testable in a target that cannot spawn a process. `LSPSourceGatingTests`
enforces the split statically: no `Sources/PisakaCore` file of this layer may
mention `Process`, `AppKit`, `UIKit` or `SwiftTreeSitter`, and every app-side file
of it must be wrapped in `#if os(macOS)`. Files are *discovered* by a per-side
prefix list (`LSP`, plus `SourceViewer` and `Hover` in the app and
`CompletionEditPlan`/`HoverContent`/`RoutingIntelligenceProvider` in Core — the
layer's members that are named for what they decide rather than for the
protocol; the hover popover's two app files are as `AppKit`-dependent as
`LSPProcessTransport` and exist only because a server can answer the question,
so a prefix sweep over `LSP` alone would leave them unpinned), and the
discovered set is then pinned by **set equality against a named list on both
sides**, in the `SymbolQueryTests` mould. Both halves need it, for slightly
different reasons: a rename that empties a prefix leaves a suite that passes while
checking less and less — and on the Core side every assertion is *negative* ("does
not mention `Process`"), which a shrinking set cannot be told apart from — while a
new file matching a prefix is one somebody has to have looked at, and the list is
what the next reader consults to know what this layer put where.

**The stack, bottom to top.** `LSPFraming` (bytes) → `LSPMessage` (JSON-RPC
envelopes) → `LSPProtocolTypes` (LSP bodies) + `LSPPositionMap` (offsets ↔
positions) → `LSPTransport` (the platform seam) → `LSPSession` (one conversation)
→ `LSPServerDescription`/`LSPServerRegistry` + `LSPWorkspace` (which server, which
root, when to give up) → `LSPIntelligenceProvider` (protocol answers as seam
values) → `RoutingIntelligenceProvider` (LSP first, tree-sitter otherwise).
`CompletionEditPlan`, `HoverContent` and `RenameEditPlan` hang off the side of
the last two: the pure rule the editor applies an auto-import with, the pure
normalization a hover answer is drawn from, and the pure plan a `WorkspaceEdit`
becomes before anything is allowed to write it. Beside them, not below anything, runs the push
channel: `Diagnostic`/`DiagnosticShift`/`DiagnosticStore` are the pure half of
it, `DiagnosticsModel` its one observable, fed by `LSPWorkspace.onDiagnostics`
and read by three macOS surfaces.

The decisions D1–D10 the ticket delegated are written out at the end of this
document, together with the limits they carry.

## Files

  - `LSPMessage.swift` — JSON-RPC 2.0 envelopes, and the *only* thing in the
    stack that knows nothing about LSP. `JSONValue` is a Foundation-only any-JSON
    value that survives a decode/re-encode round trip without knowing its schema —
    which the protocol genuinely needs twice over: a server may answer
    `textDocument/definition` with three different shapes, and it attaches opaque
    `data` to a completion item that must be echoed back **verbatim** on
    `completionItem/resolve` (sourcekit-lsp's is a `{sessionId, itemId, uri}`
    triple; mangle it and the resolve answers nothing). `int` and `double` are
    separate cases on purpose: JSON has one number type, but request ids and
    character offsets are integers, and re-encoding `1` as `1.0` makes a response
    fail to correlate on a strict server. `LSPRequestID` is an int **or** a string
    because a server-initiated request may use either and the reply must echo the
    id back in the form it arrived — this client only ever sends integers.
    `LSPErrorCode` is a `RawRepresentable` struct rather than an enum, so a code no
    version of the spec lists round-trips instead of failing to decode. The three
    outgoing envelopes (`LSPRequestMessage`, `LSPNotificationMessage`,
    `LSPResponseMessage`) double as the incoming ones, and `LSPIncomingMessage`
    resolves a peer payload into exactly one case by the spec's own
    discrimination: `method` **with** an id is a server request, `method` without
    one is a notification, no `method` at all is a response — including one whose
    id we no longer hold, which decodes faithfully here and is dropped a layer up
    rather than being a parse failure. **A present `null` and an absent member are
    different facts** and `decodeIfPresent`/`encodeIfPresent` collapse them, so two
    private container helpers keep the distinction: `"result": null` (the answer to
    `shutdown`, and to a definition request that found nothing) must be
    distinguishable from a response that carried no `result` member at all. Outgoing
    payloads go through one encoder with `sortedKeys` (byte-stable, so a test can
    assert on bytes and a recorded transcript stays diffable) and
    `withoutEscapingSlashes` (so a `file:///…` URI stays readable).

  - `LSPFraming.swift` — the base protocol's `Content-Length` header block,
    `\r\n\r\n`, then exactly that many bytes. `encode` frames one payload;
    `Decoder` is an incremental value type with a `mutating append` that accepts
    arbitrary chunks and yields zero or more complete payloads, because a pipe
    hands over whatever the kernel had ready — half a header, three messages at
    once, one message in eleven reads. Header field names are matched
    case-insensitively and values whitespace-trimmed (both required by the spec);
    `Content-Type` and anything else are ignored, since their absence changes
    nothing and their presence must not break us. The body is taken **by length**
    and never scanned, so a payload containing `\r\n\r\n` is harmless. Two caps
    exist so a peer that is not speaking LSP cannot make us grow a buffer forever:
    `defaultMaximumContentLength` (64 MiB) and `defaultMaximumHeaderLength` (8 KiB).
    **A framing error is terminal**, and that is the file's central decision: once
    the header block cannot be read there is no way to know where the next message
    starts, resynchronising would mean guessing, and a guess that lands mid-body
    feeds the JSON layer garbage that looks like a real message — so the decoder
    poisons itself instead (every later `append` rethrows the same error) and the
    session's answer is to tear the process down and let D7 restart it. A payload
    already decoded earlier in the same chunk is dropped with the error rather than
    delivered alongside it: the caller's only response to a framing error is to kill
    the connection, so delivering both would buy nothing and complicate every call
    site. `LSPFramingError` names the six ways a stream stops being readable;
    `duplicateContentLength` is refused rather than resolved because two lengths are
    two framings of the same bytes and picking either is a coin flip that desyncs
    the stream.

  - `LSPProtocolTypes.swift` — the message bodies this phase uses, and
    deliberately no more. Two rules run through all of it. **Decode leniently,
    encode exactly**: a server is a program someone else ships, so anything we might
    *receive* tolerates every legal spelling and ignores the rest, while anything we
    *send* is written one way only, because a request the server cannot parse is a
    request that never gets answered. **Open sets stay open**: `LSPCompletionItemKind`
    and friends are `RawRepresentable` structs, not enums, so a newer server's
    unknown kind round-trips instead of taking a perfectly good completion down
    with it.
    `LSPMethod` spells every method name once — a typo is answered by
    `MethodNotFound` at runtime and by nothing at compile time, and the same
    strings are matched against in `LSPSession`'s dispatch.
    `LSPDefinitionResponse` normalises the four shapes a definition answer may
    take (`null`, `Location`, `Location[]`, `LocationLink[]`) into
    `[LSPDefinitionTarget]`; the alternatives are distinguishable by JSON structure
    alone, so first-match-wins is unambiguous, and an empty array means the same as
    `null`. `LSPDefinitionTarget.jumpRange` is `selectionRange ?? range`, so the
    richer `LocationLink` answer lands on the declaration's *name* and the plainer
    `Location` still lands somewhere sensible.
    `LSPHoverResponse` does the same normalising job for hover that
    `LSPDefinitionResponse` does for definition, over a wider set of spellings:
    `null`, a bare `MarkedString` (a plain string, which the spec says is
    markdown, **or** `{language, value}`), an array mixing both, or a
    `MarkupContent` (`{kind, value}`) — plus the optional `range` the answer
    covers. All of them decode to an ordered `[LSPHoverElement]`, whose two cases
    are the only distinction anything downstream acts on: `.code(language:value:)`
    is a code block in a language the server named, `.markup(kind:value:)` is a
    string to be read as markdown or as plain text. **Order and each element's
    declared language survive verbatim**, because they are the whole input to
    `HoverContent`'s normalization — a `MarkedString` object flattened into prose
    is a type signature drawn in the interface font with its `<`/`>` read as
    markup. Leniency is per *element* here rather than per response: a malformed
    element of an array is dropped and the rest are kept, an object carrying
    neither `kind` nor `language` is read as plain text (it did send a `value`,
    and showing it unstyled beats showing nothing), a `range` that does not parse
    is simply absent, and `LSPMarkupKind(spelling:)` degrades an unrecognised
    `kind` to `plaintext` — a stray `*` on screen against a lost popover. A top
    level that is neither `null` nor an object still *throws*, exactly as for
    definition: "nothing to show" and "I could not read the answer" are different
    facts. `isEmpty` means "no elements at all"; whether the elements that *are*
    there amount to anything worth drawing is `HoverContent`'s question (D25).
    `LSPCompletionEdit` decodes both `TextEdit` and `InsertReplaceEdit` even though
    `insertReplaceSupport` is not advertised — a server that sends the second anyway
    would otherwise take the whole list down — and re-encodes in the plain spelling,
    the only one this client sends. `LSPCompletionItem.insertedText` follows the
    spec's precedence (`textEdit.newText`, else `insertText`, else `label`), which
    the recorded transcript makes concrete: one sourcekit-lsp item spells itself
    three ways — label `greet(name: String)`, filterText `greet(:)`, insertText
    `greet()`. `rankingKey` is `sortText ?? label` (D6) and `needsResolve` is
    "carries `data` but no `additionalTextEdits`", the server's own signal that it
    kept something back.
    `LSPClientCapabilities` is a **closed, hand-written** capability tree rather
    than a pass-through, because a capability is a promise a server reads and acts
    on: advertising something the editor has no code for is how a client ends up
    with snippet syntax in its buffer. It states full text sync only, `utf-16`
    positions (the default, but said out loud because a server that supports utf-8
    will happily switch if asked), definition with `linkSupport`, completion with
    `contextSupport` and `resolveSupport` for `additionalTextEdits`/`detail`,
    hover with `dynamicRegistration: false` and `contentFormat: ["markdown",
    "plaintext"]`, and **no** `snippetSupport` (D5). Both hover formats are asked
    for on purpose and in that order: markdown is the only way a server marks a
    type signature as *code* rather than as prose, and `HoverContent` degrades the
    rest of the markup rather than rendering it — while plaintext is listed beside
    it so a server with no markdown renderer answers instead of declining. That is
    the closed tree's own rule applied to a new node: what is advertised is what
    there is code for, and there is code for exactly these two.
    D35/D36 add three more nodes under the same rule, because the two requests they
    introduced are requests this client *sends*: `textDocument.references` and
    `textDocument.rename` (both `dynamicRegistration: false`, and rename with
    `prepareSupport: false` — `textDocument/prepareRename` is never sent, since
    `RenameNameRule` already decides what the caret is on and what a new name may
    be, and a second round trip to be told the same thing would only add a failure
    mode between the shortcut and the dialog), plus `workspace.workspaceEdit`, which
    is where the promise actually bites. It states `documentChanges: false` (the
    per-document versions the richer spelling adds are the one thing
    `RenameEditPlan` deliberately does not compare — it verifies the bytes instead —
    so it buys nothing), `failureHandling: "abort"` (what `apply` does: it stops at
    the first write that throws and the writes before it stay written) and
    **`resourceOperations: []`**, the load-bearing one. D38 adds the ninth and last
    node, `textDocument.foldingRange`, under that same rule and closed like the
    rest: `lineFoldingOnly: false` (this editor hides a character range, not a run
    of whole lines, so a character-precise server is taken at its word about
    the *end* — its **start** is floored at the header line's content end, the
    one place a server is second-guessed, because `FoldRegion`'s "the header
    line stays visible in full" is load-bearing rather than a preference),
    `collapsedText: false` (the placeholder is always `…`; a server-supplied one
    would be a second vocabulary to render) and a `foldingRangeKind.valueSet`
    naming exactly the three `FoldRegionKind` cases — the closed table a kind
    outside it is read as *absent* against. The wire types are
    `LSPFoldingRangeParams`/`LSPFoldingRange`/`LSPFoldingRangeResponse`, decoded
    leniently element by element (an unreadable entry is dropped, a non-array
    top level throws) exactly as every other list response is. A create/rename/delete entry
    is not something this editor performs: `LSPWorkspaceEdit` drops it and applies
    the textual half, which for a module rename would leave every reference renamed
    and the file still under its old name. Declaring the empty set is what tells a
    conforming server not to offer one, so that drop stays *unreachable* rather than
    merely unlikely — and a server that would have answered with a file move refuses
    the rename outright instead, which is the honest outcome.
    The diagnostics wire shape (D29–D31) follows both file rules. **Decode
    leniently**: `LSPDiagnostic` requires only `range`/`message` — the spec types
    everything else optional — and each optional reads through a failure-tolerant
    path, so an unknown `severity` number or an opaque `code` decodes to its
    presence rather than failing the push; one malformed entry of a
    `diagnostics` array is dropped while its siblings survive,
    `LSPHoverResponse`'s per-element rule; and
    `LSPPublishDiagnosticsParams.version`, absent or unreadable on most servers,
    stays `nil` — D31 then accepts the push against revision alone rather than
    inventing a version to compare. **Encode exactly** barely applies, because
    the whole shape is decode-only: the server initiates this conversation and
    Pisaka never sends it. The closed capability tree gains its honest node:
    `textDocument.publishDiagnostics` with `relatedInformation: false` (no
    surface for the related spans exists) and `versionSupport: true` (the
    workspace does read `params.version`) — advertised because there is code
    behind it, which is the tree's whole rule.
    `LSPInitializeParams` sends the project root **twice** — as `rootUri` and as
    the spec-deprecated `rootPath` — and the redundancy is load-bearing rather
    than belt-and-braces. Phase 2a sent only `rootUri`, which is what
    sourcekit-lsp and typescript-language-server read; **pyright reads neither
    that nor anything derived from it.** Its `WorkspaceFactory.handleInitialize`
    registers workspaces from `workspaceFolders` when present and from `rootPath`
    otherwise, and from nothing else, so an initialize carrying only `rootUri`
    leaves it with *no* workspace at all: every request falls to its rootless
    `<default>` workspace, with no project root, no
    `pyrightconfig.json`/`pyproject.toml`, no execution environments and no
    venv/`extraPaths` discovery. That failure is silent in both directions —
    pyright answers `null` rather than erroring, and `RoutingIntelligenceProvider`
    reads `null` as "the server found nothing" and falls back — so the symptom is
    not a broken Python server but a Python server that never beats the
    tree-sitter index on any import that is not resolvable from the open file's
    own directory. Confirmed against the pinned pyright 1.1.411 bundle: the same
    cross-file `textDocument/definition` answers `null` with `rootUri` alone and
    the correct location with `rootPath` added.
    `workspaceFolders` — the key pyright checks *first* — would work equally well
    and is the non-deprecated spelling, but the spec only permits sending it
    alongside a `workspace.workspaceFolders: true` capability, which is a promise
    to implement `workspace/didChangeWorkspaceFolders` and to answer the
    `workspace/workspaceFolders` request. This client does neither, and never
    needs to: a root cannot change within a session, because a different root is a
    different `(server, root)` key and therefore a different process. Sending the
    deprecated field costs one line and no promise; advertising the capability
    would put a lie in the closed tree below to buy nothing. `LSPWorkspace.rootPath(for:)`
    derives it from the same standardized, *unresolved* URL as `rootURI(for:)`, so
    the two always name one directory — a server resolving imports under one
    spelling while being handed documents under another is exactly the bug this
    pairing must not introduce.
    `LSPServerCapabilities` models only what this phase acts on; everything else a
    server advertises is ignored rather than typed, since twenty providers we never
    call are not information. `definitionProvider`/`hoverProvider`/`completionProvider`
    are `boolean | Options` on the wire and all three spellings collapse to one
    question (an options object *is* support). `usesUTF16Positions` is the one
    capability that can disqualify a server outright — see D7's terminal failures.
    `supportsHover` is the only one of the three that is *read before asking*
    (D25): the other requests would merely waste a round trip on a server that
    cannot answer them, while hover fires whenever the pointer stops moving, so an
    unanswerable question there is a question asked forever.
    `supportsReferences` and `supportsRename` are read the same way and through the
    same collapse (`referencesProvider`/`renameProvider` are `boolean | Options`
    too, and `renameProvider`'s options spelling carries `prepareProvider`, which is
    read as nothing more than the presence that makes the collapse say yes —
    `textDocument/prepareRename` is deliberately never sent, because the app asks
    for the new name through its own validating dialog). Both are *read before
    asking*, for a reason that is neither definition's nor hover's: an unanswerable
    references request costs the user the whole three-second budget before the model
    gives up and walks the project — which is the answer they were going to get —
    and an unanswerable rename request costs them the same wait to be told the
    command is not available.
    **The references pair.** `LSPReferenceParams` is a position request plus
    `LSPReferenceContext`, whose single member is `includeDeclaration` and whose
    value on the wire is always `true`: the declaration is a usage the person who
    asked expects to see, and a list that silently omits the row they were looking
    at is worse than no list. `LSPReferencesResponse` folds `null`, an absent
    `result` and an empty array into one empty answer, exactly as
    `LSPDefinitionResponse` does; leniency is **per element** (`publishDiagnostics`'
    rule — one unreadable location must not cost the other four hundred), while a
    top level that is neither `null` nor an array still throws, because "found
    nothing" and "could not read the answer" stay different facts.
    **The rename pair.** `LSPRenameParams` adds `newName` and nothing else.
    `LSPWorkspaceEdit` is the one type here that normalises across two *spellings of
    the same answer*: `changes` (a uri → `[TextEdit]` map) and `documentChanges` (an
    ordered array of `{textDocument: {uri, version}, edits}`). `documentChanges`
    wins when both are present — it is ordered, it carries the version, and it is
    what a client advertising support for it is supposed to receive — and `changes`
    entries are **sorted by URI**, because an unordered dictionary must not let one
    answer produce two different plans on two runs. A `documentChanges` array may
    also hold `CreateFile`/`RenameFile`/`DeleteFile` operations (or a kind no
    version of the spec names): those are **ignored rather than fatal**, since
    nothing here performs file operations and refusing the whole answer would turn
    a server that helpfully offers to rename the file too into a server that cannot
    rename at all. **The leniency stops at the edits themselves**: a
    *`documentChanges` entry that is not a text edit at all* is dropped, and
    everything that claims to be one and cannot be read as one fails the whole
    decode, at which point the command beeps as it does for a server that refused.
    The two are not the same case — dropping a non-text-edit entry loses nothing
    the rename promised, while dropping one edit out of a document's five yields a
    `WorkspaceEdit` that is internally consistent, passes every refusal in
    `RenameEditPlan`, and writes a project renamed in four places out of five. This
    is the one answer in the file that becomes a write, so it is the one decoded
    all-or-nothing. **`textDocument` is what tells the two apart**, and it is the
    only thing that does: a file operation names its files with
    `uri`/`oldUri`/`newUri` and never carries one, so an entry that *does* carry a
    `textDocument` is a document this rename must rewrite and an unreadable `uri`
    or `edits` on it **throws** rather than being read as an operation to decline —
    and the entry is required to be a JSON **object** before that question is even
    asked, because `JSONValue`'s subscript is `objectValue?[key]`: a string, a
    number or an array answers `nil` for `textDocument`, indistinguishably from a
    file operation, so without the object test a garbled entry beside four good
    ones would be *dropped* and produce exactly the half-renamed project this rule
    refuses. A file operation is a stated non-edit; a scalar is a malformed answer
    whose intended target this client cannot know —
    reading it as one would keep its siblings and produce the half-renamed project
    one level up from the single dropped edit. For the same reason an unreadable
    entry of the **`changes`** map throws rather than being dropped: that map holds
    no file operations to be tolerant of, so every value in it is one document's
    edits and skipping one is precisely the half-renamed project, arriving through
    the third spelling. **The rule holds at the member level too**, which is where
    it is easiest to lose: a `documentChanges` that is *present and is not an
    array* throws rather than being swallowed, because falling through to
    `changes` would write the unversioned half of an answer whose richer half this
    client could not read — the very edit set "`documentChanges` wins" says is
    superseded — and falling through with no `changes` beside it would report the
    empty answer a server gives when it has nothing to rewrite, so the command
    would beep as though the rename were a no-op rather than unreadable. A
    `changes` that is present and is not a map throws for the same reason. Only
    *absent* — which includes `null`, since that is what `decodeIfPresent` says —
    is "this server sent no such member". **An empty array is present**, and is
    therefore the answer: `documentChanges: []` is the richer member saying there
    is nothing to rewrite, and falling through to `changes` there would turn the
    one answer that means "no rename" into a write of the edit set that member
    supersedes. A non-empty array of nothing but file operations already decodes to
    no documents by the drop rule above, so reading the empty array any other way
    would make the emptier answer the more dangerous one.
    One document may legitimately appear more than once; entries stay
    in wire order and grouping is `RenameEditPlan`'s job, not the decoder's.
    `LSPDocumentEdits.version` is **kept and never compared** (D37): the plan
    verifies each range still holds the exact text the edit was computed against,
    which catches everything a version would and also holds for the servers that
    send none. `isEmpty` — no edit anywhere — is the answer a server gives when it
    recognised the symbol but has nothing to rewrite, and the command treats it
    exactly as it treats a refusal.

  - `LSPPositionMap.swift` — the bridge between the editor's one coordinate (a
    UTF-16 buffer offset) and LSP's `(line, character)` pair. **It deliberately does
    not use `LineStartIndex`** (D1), and that is the whole reason the file exists:
    `LineStartIndex` splits on everything `NSString` calls a line separator — LF,
    CR, CRLF, NEL, LS, PS — because the gutter, the minimap and TextKit must agree
    with each other, while LSP's base protocol counts lines with **LF, CRLF and CR
    only**. The number we send has to be the number the server counted, so this
    scanner implements the server's rule.
    `lineStarts(in:)` is always non-empty (an empty document is one line) and a
    document ending in a separator gets a final entry at `length` — the empty last
    line is a real position a server can point at. `position(forOffset:…)` clamps an
    out-of-range offset rather than rejecting it: it can only come from a caret the
    editor already moved. `offset(for:…)` clamps in both dimensions, because this is
    where a *server's* numbers enter the editor and they are not to be trusted with
    an `NSString` index — a line past the end resolves to the end of the buffer, and
    a character past the end of its line resolves to that line's content end, before
    the separator, so a jump never lands on the invisible half of a CRLF. **The
    clamp is applied to `character` itself, not to `start + character`**, and that
    ordering is the whole of it: `character` is an `Int` decoded straight off the
    wire, so summing first would trap on overflow before any `min` could see the
    number — a hard crash of the editor on one malformed response, on the one path
    where every other failure degrades quietly to tree-sitter.
    `LSPPositionMapTests.testAnAbsurdCharacterClampsInsteadOfOverflowing` pins it
    with `Int.max`. Both
    have a variant taking precomputed line starts, so a caller mapping several
    positions in one buffer scans it once; `offset(for:in:lineStarts:)` still needs
    `content` because clamping to a line's end means knowing whether the separator
    that follows is one code unit or two, which a list of starts cannot say.
    `range(for:in:)` normalises a range whose `end` precedes its `start` — servers
    do send those, and `NSRange` cannot represent one — into an empty range at
    `start` rather than a negative length that traps at the call site. It has the
    same precomputed variant, for the same reason and one hotter caller: a
    completion list maps one range per item against one buffer, and the one-shot
    form would scan that buffer once per item.
    **The interior of a CRLF pair is not an addressable LSP position.** The
    exhaustive round-trip test surfaced this; both directions agree to clamp it to
    the line's content end, and
    `LSPPositionMapTests.testAnOffsetInsideACRLFPairIsNotAnAddressablePosition`
    states it outright instead of the round-trip assertion being quietly weakened.
    `lineIndex(containing:lineStarts:)` is internal — not `private` — for the
    same one-rule reason the rest of the file exists: the diagnostics layer
    (`Diagnostic.make`, `DiagnosticShift.updated`,
    `DiagnosticStore.worstSeverityPerLine`) reuses exactly this offset→line
    search against this table rather than growing copies that could drift.

  - `LSPTransport.swift` — the whole macOS/Core boundary, and deliberately tiny:
    bytes out (`send`), bytes in (`incomingBytes`), stop (`terminate`). The
    one-way-ness is the point. A transport never interprets a message, never
    retries and never restarts anything: **a crashed server is reported by the byte
    stream *finishing***, and deciding what that means is `LSPWorkspace`'s job,
    because it is the only thing that knows how many times it has already happened.
    `incomingBytes` carries the bytes the server wrote in whatever chunks the pipe
    delivered them — re-assembly is `LSPFraming.Decoder`'s job — and is **consumed
    exactly once**, by the owning session: an `AsyncStream` has a single consumer,
    and a second `for await` would silently split the message stream in two.
    `terminate()` must be idempotent (the session calls it on every terminal path)
    and must finish `incomingBytes`, because a stream that never ends is a read task
    that never exits. `LSPTransportError` names the ways bytes fail to move and is
    deliberately **not** `LocalizedError`: nothing on this path is ever shown to
    anyone (D7). Three of its cases are failures (`launchFailed`, `notRunning`,
    `writeFailed`); `notReady` is not one — it says the factory declined to answer
    *yet* rather than block the main-actor turn it was called on, and `LSPWorkspace`
    spends no restart budget on it (see `LSPToolchain`).

  - `LSPSession.swift` — one live conversation with one server process: the
    handshake, the id counter, the pending-request table, and the rules for every
    way a conversation can end. It knows nothing about projects, languages or a
    second server. An `actor` because its state is touched from three directions at
    once — caller tasks issuing requests, the read task delivering messages, and
    per-request timeout tasks firing.
    **Every request has a deadline** (D7), carried by the nested `Budgets` type:
    handshake 20 s (sourcekit-lsp resolves a build system on first start),
    definition 3 s, completion 1.5 s, plus two the plan left implicit and the type
    states outright — `resolve` 1.5 s (D4's background prefetch) and `shutdown` 2 s
    (short on purpose: the process is being killed either way, and this is only the
    difference between a clean exit and a SIGTERM) — and `hover` 1.5 s, which is
    **completion's number rather than definition's** (D25): nobody asked for a
    hover deliberately, the pointer merely stopped moving, so an answer arriving
    after it has moved on is not late but unwanted, and waiting a definition's
    three seconds only keeps a request alive past its own usefulness.
    `hover(_:)` is the exchange itself, decoded through the same
    `decode(_:as:method:)` so a missing `result` and an explicit `null` stay one
    answer; whether the server was worth asking at all
    (`capabilities.supportsHover`) is the *provider's* check, not this layer's — a
    session answers what it is asked.
    `references` 3 s is the seventh budget and the one shared by two methods:
    `references(_:)` and `rename(_:)` both take **definition's number, for
    definition's reason** — each is a command someone typed a shortcut for rather
    than a pointer that happened to stop, so the answer is still wanted when it
    arrives late — and they share one span because they are the same act asked two
    ways, where two numbers would only be two numbers to keep in step.
    `references(_:)` and `rename(_:)` are the exchanges themselves, in `hover(_:)`'s
    exact shape (encode the params, `request` with the budget, `decode`), and
    `supportsReferences`/`supportsRename` are the provider's check for the same
    reason `supportsHover` is. **Nothing is written here**: a rename request is a
    *read* like every other exchange in this actor, and what to do with the answer —
    verify it, then apply it or abort — belongs to the layer that holds the writer
    bracket.
    `foldingRange` 1.5 s is the eighth budget, and it takes **completion's number
    for hover's reason** (D38): nobody asked for a chevron either — the question
    fires behind every typing pause — so an answer that arrives after the buffer
    has moved on is unwanted rather than late. `foldingRange(_:)` is the exchange,
    in `hover(_:)`'s exact shape, and `supportsFoldingRange` is the provider's
    check for the same reason the other three are. A request that outlives its
    budget fails **alone**: nothing else in the table is touched, because one slow
    answer is not evidence the server is broken, and the server is sent
    `$/cancelRequest` since we will not read the reply.
    **The end is terminal.** EOF, a framing error, a failed handshake and a
    graceful `shutdown` all land in `close(reason:)`: the phase goes `.terminated`,
    every pending continuation is failed **exactly once**, the read task is
    cancelled and the transport terminated. There is no `.restarting` state —
    restart is `LSPWorkspace`'s decision, because a session that resurrected itself
    would hide the crash loop D7 exists to bound.
    **The owner keeps it alive.** The read task holds `self` *weakly*, so a session
    nobody references stops reading. That is deliberate — a strong self would keep
    every session and its process alive until the server itself exited, which is
    exactly what "drop it and restart" cannot afford — but it makes retention a
    contract: `LSPWorkspace` owns sessions, and anything else holding one for the
    length of a conversation has to say so. (Three tests caught this by discarding
    the session and watching server-initiated requests go unanswered.)
    **We answer, never initiate policy.** Every server-initiated request gets a
    reply, because a server blocked on an answer we never send will happily stall
    the request we are waiting on: `client/registerCapability` and
    `client/unregisterCapability` get `null` (dynamic registration is declined in
    the capabilities, so a server should not ask; acknowledging is cheaper than an
    error it might treat as fatal), `workspace/configuration` gets one value per
    requested item — this server's own section where its description names it, and
    `null`, "no setting", where it does not (D27) — and anything else gets
    `MethodNotFound`. For the five servers whose description carries no
    configuration that is one `null` per item, byte-for-byte the answer this file
    gave before D27 existed. **Notifications are forwarded, never interpreted**
    (D29): since the diagnostics work, `handle(_:)`'s `.notification` case yields
    an `LSPServerNotification` (method + params, nothing session-shaped attached)
    into `notifications: AsyncStream<LSPServerNotification>` instead of dropping
    it. The stream is built in `init` around a single continuation with
    unbounded buffering, because its one consumer (`LSPWorkspace`, attached once
    the handshake has succeeded and the session is filed under its key) always
    drains it: the buffer is what makes attaching *after* `start` safe — anything
    the peer says during the handshake waits rather than being dropped — and a
    burst of pushes between two hops of that consumer must not strand anything
    either — a callback would have let two
    pushes reorder across two independent `Task` hops and leave stale errors on
    screen for the life of the session, which is the whole reason this is a
    stream (D29). Finishing is exactly once and exactly terminal: `close(reason:)`
    is already the single transition every ending funnels through, so it is where
    the continuation finishes, and D33 reads that finish as the externally-killed-
    server signal without this file learning anything about diagnostics. What a
    notification *means* — route a push, ignore a log — is the consumer's
    business; this layer guarantees only wire order and delivery, which is why
    an unrecognised method is ignored there rather than here.
    **A framing error is terminal, a bad *payload* is not.** `ingest` distinguishes
    the two: unreadable framing closes the session (there is no way to find where
    the next message starts), while a correctly framed payload that is not a
    JSON-RPC message is dropped and the stream read on — exactly one message is
    lost, and the alternative would kill a live server over one malformed
    notification.
    The deadline task starts *after* the write, so the budget covers the server's
    thinking and not our own encoding; the pending entry is registered
    synchronously before any suspension, so a cancel that fires immediately still
    finds it; and `pendingRequestCount` is a test seam asserting directly that a
    cancelled, timed-out or failed request leaked no continuation.
    `LSPSessionError` is separate from a server's own `LSPResponseError` because
    the two are different facts and a caller deciding whether to fall back cares
    about the difference — `MethodNotFound` says this server will never answer this
    question, `timedOut` says nothing about the next request.

  - `LSPServerDescription.swift` — everything the app needs to *start* one server,
    and nothing about how to talk to it (D9). The whole point is that adding a
    server is a **data** change: phase 2b added TypeScript and Python by composing
    two of these from a pinned manifest, and no client code moved, because nothing
    above this file knows the word "sourcekit". `LSPWorkspaceTests` pins that
    promise by serving a second, entirely fictional server through configuration
    alone, and `LSPProvisioningModelTests` pins the other half — that the two
    appended descriptions leave the Swift path byte-identical.
    `Launch` is a *description*, not a resolution — `.toolchainTool(name:)` for a
    tool inside the active Xcode toolchain (resolved by the app with `xcrun --find`,
    honouring `DEVELOPER_DIR`) or `.executable(path:)`, which is what 2b's
    provisioned servers are — which
    keeps the value type comparable and testable without an Xcode installation
    anywhere in sight. `id` is half of the `(server, root)` key D7's failures are
    counted against; `languages` is a `Set` because a real server often serves
    several; `initializationOptions` is an opaque `JSONValue` passed through
    verbatim, since it is *that server's* configuration and Core has no business
    having an opinion about its shape.
    `configuration` is the second opaque value and is opaque for the same reason,
    but the two are not interchangeable (D27): `initializationOptions` travels once,
    inside `initialize`, while `configuration` is a settings object **keyed by the
    section a server asks for** (`{"yaml": {…}}`) and answers the two channels a
    server may take settings on afterwards. `nil` for every server but the YAML
    one, and `nil` is a statement rather than a default — it is what makes the
    handshake of the other five byte-identical to what it was.
    `environment` is an **overlay and never a replacement** — the app merges it on
    top of the process environment rather than assigning it, so everything a server
    resolves out of `PATH`/`HOME`/`DEVELOPER_DIR` keeps working. It is empty for
    every server but gopls: sourcekit-lsp answers through `xcrun`/`DEVELOPER_DIR`,
    and `typescript-language-server` and pyright are launched as an absolute-path
    `node` plus an absolute-path script, resolving nothing by name. gopls is the one
    that looks a *second* executable up on `PATH` — see
    `LSPGoToolchainReport.found`'s `searchPath` below. It is carried on the
    description rather than resolved at launch for D9's reason: the value is
    machine-specific knowledge, so the app finds it and Core only passes it along.
    `sourcekitLSP` is the only entry `.standard` holds, with **no**
    `initializationOptions`: it discovers the build system from the root it is
    initialized with, and a project it cannot make sense of answers nothing — which
    is exactly the case the routing provider falls back for. It is no longer the
    only entry the *workspace* ever sees: `LSPProvisioningModel` appends one per
    installed server and pushes the result through `updateRegistry(_:)` (D16),
    always after the base entries, so first-registration-wins keeps this one
    winning for `.swift`.
    `LSPServerRegistry` maps language → description, resolved once at construction
    so the request-path lookup is a single dictionary hit. **First registration
    wins** on a conflict: arbitrary but stated, and it makes composition order
    meaningful. `.standard` is the app's registry; `.empty` is what iOS and a good
    many tests want, and makes routing degrade to tree-sitter for everything with no
    special case anywhere.
    `SyntaxLanguage.lspLanguageID` is a `switch` rather than `rawValue` because a
    server keys its parser off this string — it is the *protocol's* spelling, and a
    language added to the enum must be spelled here deliberately, which the compiler
    enforces. Two are not in the spec's list and follow what editors settled on:
    `.dotenv` (no server speaks it; present only so the mapping is total) and
    `.gitignore` → `"ignore"`.
    `lspLanguageID(forFileNamed:)` is what `LSPWorkspace` actually sends, because
    for the JS/TS family the id is a property of the *document* and not of the
    language: `SyntaxLanguage` deliberately collapses `.tsx` into `.typescript`
    and `.jsx` into `.javascript` (one grammar, one keyword list, one symbols
    query), while LSP names those `typescriptreact`/`javascriptreact`.
    `typescript-language-server` hands the id straight to tsserver as a script
    kind and corrects a wrong one *only* when it is not a mode it recognises —
    `"typescript"` is one, so a `.tsx` announced that way is not corrected and is
    opened as `ScriptKind.TS`, whose language variant parses no JSX. The server
    then answers, wrongly, about every identifier in the JSX half of the file, and
    an answer is the one failure `RoutingIntelligenceProvider` cannot fall back
    from. `.jsx` is harmless either way (tsserver's `ScriptKind.JS` already parses
    JSX) and is spelled out for the same reason the rest of the mapping is a
    `switch`.

  - `LSPWorkspace.swift` — which servers are running, for which project, holding
    which documents open, and when to stop trying. `@MainActor` for
    `SymbolIndexModel`'s reason: the bookkeeping is touched from the editor's own
    turn (a folder switch, a tab close) and must be **synchronous** there, so
    `prepareForFolderChange` can pin a generation before any hop. It owns three
    things no session can own for itself.
    **One server per `(server, root)`**, started lazily on the first request for a
    language it serves — lazily because a project with no Swift in it must not pay
    for sourcekit-lsp resolving a build system, and per-root because a language
    server's whole model is a workspace. A second request arriving while the first
    is still handshaking *waits for it* rather than starting a second server, which
    is the difference between "lazy" and "once".
    **What the server has been told.** D2's sync is request-driven: nothing is
    pushed on a keystroke, and every request calls `prepare(url:language:text:)`
    first, which sends a `didOpen` (or a `didChange` with a bumped version) exactly
    when the text differs from what *this* server was last given, and nothing at all
    when it does not. The one caller that declines that no-op is the diagnostics
    sync, through `prepare`'s defaulted `forceFlush`: a push-only server publishes
    only when a notification arrives, so when another flusher (a completion at its
    shorter debounce, a hover) has already delivered the settling sync's exact text
    — its publish then dying at the model's gate, version past the record — the
    sync must still leave one version-bumping full-text `didChange` behind, or the
    burst ends with no accepted push anywhere (D30/D32). A document is never opened
    against a root it does not live
    under: a server initialized for one project has no business being told about a
    file from another, and the answers it gave would be about the wrong build.
    **The flush is serialised per document**, through the `flushes` table (the
    `pendingLaunches` id discipline, applied to a URI): a second request for the same
    file waits for the flush already running rather than interleaving with it. The
    body is a read-modify-write over `documents[uri]` with an `await` in the middle,
    and overlapping requests for one file are the ordinary case rather than an exotic
    one — everything queued behind a cold launch resumes in the turn the handshake
    lands, and a request the router abandoned at its deadline keeps flushing while
    the next one starts. Interleaved, two of them send two `didOpen`s for one URI or
    two `didChange`s carrying the same version, and — the damaging half — leave
    `documents[uri]` recording text this server was never sent, which the next
    request reads as "nothing to send" and then asks its question against the wrong
    file, silently, until the buffer changes again. The "text unchanged" answer is
    given before the claim, so a second request at the same keystroke still costs
    nothing.
    **`didClose(url:)` takes the same claim**, and must. Closing a tab is one of the
    things that supersedes a completion, so a close landing while a `didChange` for
    that file is in flight is the common shape rather than an exotic one — and
    without the claim the two interleave in the one way that does lasting damage:
    the close drops `documents[uri]`, and the notification already on its way stores
    it *back*, leaving a document the server has been told is closed recorded here as
    open with exactly the text it holds. The next request reads that as "nothing to
    send", never re-`didOpen`s, and asks about a document the server dropped —
    silently, for the rest of the app run, since only another close or a crash clears
    the entry. `LSPWorkspaceTests`
    `.testATabClosedWhileTheBufferIsFlushingDoesNotLeaveTheDocumentRecordedAsOpen`
    stages it by holding the writer inside the `didChange` while the main actor runs
    the close.
    **What the claim cannot cover, an identity check does.** `noteDeath`,
    `shutdownAll()` and `terminateNow()` drop document state from *outside* the
    per-document claim, and must: a crash and a quit do not queue behind a keystroke,
    and `terminateNow()` cannot `await` at all. So `send` re-checks
    `sessions[key] === session` after each notification, before it stores anything,
    and throws `FlushFailure.serverReplaced` when the answer is no — read by `prepare`
    exactly like a write failure (drop the state, answer `nil`, let the next request
    re-`didOpen`). Without it a `didChange` that returned a moment before a folder
    switch resurrects its entry behind `shutdownAll()`'s clear, filed under the very
    `(server, root)` key the *next* server for that folder is filed under — a server
    that has never heard of the file. Every later flush then reads "nothing to send"
    or bumps a version against a document that was never `didOpen`ed, and that file
    answers from tree-sitter for the life of the server. `LSPWorkspaceTests`
    `.testAFolderSwitchWhileTheBufferIsFlushingDoesNotLeaveTheDocumentRecordedAsOpen`
    stages it the same way the close case is staged.
    **The generation is checked on *both* sides of the flush**, and the second
    check is not the identity check above wearing another hat. That one catches the
    *teardown*: once `shutdownAll()` has emptied `sessions`, the notification's
    write-back throws and `prepare` answers `nil`. But a folder switch is two steps
    and only the first is synchronous — `prepareForFolderChange` bumps the
    generation in the editor's turn, and the `shutdownAll()` it schedules runs a
    turn later. A flush resuming inside that window finds its session still filed
    under its key, so every defence in `send` passes, and `prepare` would hand back
    a `PreparedDocument` for the root the user has just left; the provider then asks
    the old project's server where a symbol is declared and publishes an answer
    naming a file under a closed folder. Downstream cannot tell that from a good
    answer — the document table is untouched until the teardown clears it, and a jump
    that *is* an answer never falls back — so the window is closed where the token
    lives. `LSPWorkspaceTests`
    `.testAFlushFinishingBetweenTheSwitchAndTheTeardownAnswersNothing` stages it by
    holding the writer inside the `didChange` and running the switch *without* the
    teardown. The document state `send` recorded is deliberately left in place: it
    is a true record of what that server was told, and the teardown drops it.
    **The claim is released before the request is sent, so `stillHolds(_:)`
    exists** — and it checks *both* halves of what `prepare` guaranteed, because
    `prepare` guaranteed them at prepare time and not for the life of the question.
    The **version** half: a second request carrying different text — one queued
    behind a launch, one the router abandoned at its deadline and then resumed —
    flushes in between, and the answer that comes back is about a document the
    caller's buffer no longer describes. The **generation** half is the same
    two-step-switch window as the paragraph above, reaching past `prepare` to cover
    the request itself — and that is the *wider* window of the two, since a server is
    allowed to take seconds to answer where a flush takes a write. `prepare`'s guards
    cannot see it: they run before the question is asked, the switch leaves
    `documents` exactly as it was until its scheduled `shutdownAll()`, so the version
    still matches and only the generation carried in `PreparedDocument` can tell that
    the answer belongs to a folder nobody is looking at. `LSPIntelligenceProvider`
    asks this before reading any response — for definitions *and* completions, whose
    items carry edits that are written to the file — and treats `false` as no answer
    at all, because a wrong jump *is* an answer and so never falls back.
    `LSPWorkspaceTests`
    `.testADocumentPreparedBeforeAFolderSwitchIsNoLongerCurrentAfterIt` pins the
    generation half against a document table that still holds the version, and
    `LSPIntelligenceProviderTests`
    `.testAnAnswerIsDroppedWhenTheFolderChangedWhileTheQuestionWasOutstanding` /
    `.testACompletionListIsDroppedWhenTheFolderChangedWhileItWasOutstanding` stage the
    switch while the scripted server is deliberately slow to reply. Re-opening the
    *same* folder is not a switch and invalidates nothing, since
    `prepareForFolderChange` takes its no-op path. Checking after the fact rather than
    holding the claim across the request is deliberate: the request would otherwise
    serialise every other question about that file behind a server that is allowed to
    take seconds, and the cost of the conservative answer is one tree-sitter fallback
    in a case where the world had moved on anyway.
    **`lastSentTexts()` answers the same question for the documents nobody
    prepared**, and by bytes rather than by version: the text each open document
    was last *sent*, keyed by the file URL its URI names. `stillHolds` is enough
    for every answer this layer only *reads*, because each of those is about the
    one file the question was asked in; a **rename** is the exception, since it
    answers about files no request prepared, whose coordinates the server computed
    against whatever it was last told. `PisakaApp.renameSymbol` is the one caller,
    and it reads the map **before** it sends the rename request rather than after
    the answer lands (see D37 below for why that ordering is the whole point). A file absent from the map is one
    no server holds open — the server read it from disk, and so does the caller.
    `LSPWorkspaceTests` `.testLastSentTextsReportsTheTextEachDocumentWasFlushedWith`
    / `.testLastSentTextsLagsABufferThatHasNotBeenFlushedAgain` /
    `.testLastSentTextsIsEmptyBeforeAnyDocumentIsOpenedAndAfterOneCloses` pin the
    three cases, the middle one being the whole point.
    **When to give up** (D7): three restarts with 1 s / 2 s / 4 s of backoff — the
    `backoffDelays` array's length *is* the budget — and the fourth failure marks
    that `(server, root)` unavailable for the rest of the app run. The budget is per
    `(server, root)` rather than per server, so a server that cannot cope with *one*
    project does not poison the next folder, and it is never reset within a root,
    because a server that has crashed four times on one project will not succeed on
    the fifth. **A launch failure spends it exactly like a crash** — a factory that
    throws (no Xcode, `xcrun --find` empty) must stop the retries, or a machine with
    no toolchain would attempt a process launch once per keystroke forever.
    **`LSPTransportError.notReady` is the one throw that costs nothing**, because
    nothing was attempted: the factory is `@MainActor` and called inside the launch
    turn, so the app's cannot block on `xcrun --find` and answers "not yet" while the
    lookup runs on a background queue (`LSPToolchain`). Counting it would let three
    ⌘-clicks in the first second after launch retire a perfectly good server for the
    whole app run.
    **Two failures are terminal rather than countable** and are marked unavailable
    immediately: a server that answers `positionEncoding: utf-8` (every offset in
    this codebase is UTF-16, and it will answer the same on every restart), and — the
    mirror image — **a superseded launch is not a failure at all**, so it costs no
    restart budget and pays no backoff.
    **A crash is noticed on the next request, not pushed.** `LSPSession` has no
    back-reference to the workspace (the weak-read-task contract), so `liveSession`
    asks `isRunning` and treats a dead session as the crash. That is also where the
    document bookkeeping for that server is dropped — which is why a restarted
    server is sent `didOpen` rather than a `didChange` against a document the new
    process never had.
    **One crash costs one restart even when two requests notice it.** Two requests
    in flight (a definition and a completion, say) both read `sessions[key]` and
    both suspend on `isRunning`, so both come back holding the same corpse. Only
    the one that still finds *its* session filed under the key books the death:
    `liveSession` re-reads the slot after the hop, and `noteDeath` does every
    mutation — clearing the session, the transport, the documents, and incrementing
    the counter — *before* its own `await`, so the loser finds the slot already
    empty and falls through to join the launch instead of booking a second failure.
    Without that, D7's budget of three restarts was spent in two crashes and the
    `(server, root)` went silently unavailable for the rest of the app run. The
    loser also returns a session another request restarted in the meantime rather
    than starting a second one for the same key.
    **`unavailable` is re-read after every hop that can retire the key**, not only
    when `liveSession` is entered. On the crash that spends the *last* of the budget
    both observers pass the entry check together, and the loser resumes to find the
    slot empty — neither the identity branch nor the replacement branch answers, so
    it would launch. `canServe`/`isUnavailable` already say `false` for the key by
    then, so nothing would ever route to that server: it would just be a live
    `sourcekit-lsp` holding a build-system cache until the next folder switch or the
    quit, and the contradiction of "nothing is ever launched for it again". The same
    re-read guards `launch` after D7's backoff, which is up to four seconds long —
    time enough for another request to book the remaining failures.
    **Two tokens, not one.** `prepareForFolderChange(root:)` bumps the public
    `generation` — only when the root actually changes, matching
    `SymbolIndexModel.prepareForFolderChange` so a caller can pin one token across
    both models — *and* a private `epoch`. `shutdownAll()` and `terminateNow()` bump
    only the epoch. A launch terminates the server it just started if the epoch no
    longer matches, which is what makes "a folder switch supersedes in-flight work"
    true. **The token is pinned by `liveSession` on entry, before its first
    suspension point** — the `prepareForFolderChange` discipline applied to the token
    `launch` itself checks. Reading `epoch` inside `launch` would read it after two
    suspension points a folder switch fits through comfortably: the task's own
    scheduling, and D7's backoff, which is up to four seconds long. A launch that
    pinned the *already bumped* epoch passes its own guard and files a session into
    the maps `shutdownAll()` has just emptied; the process is still reaped (the
    shutdown awaits the launch), but the map entry survives as a corpse under the old
    root's key, and the next visit to that folder charges its death against D7's
    budget — four folder round-trips and a healthy server is unavailable for the rest
    of the app run. The token is checked a second time immediately after the backoff,
    so a switch during the wait launches nothing at all.
    `LSPWorkspaceTests.testAFolderSwitchDuringTheBackoffSupersedesTheRestart` stages
    exactly that, through an injected wait. The pin sits at the *entry* rather than
    beside the launch because `liveSession` reaches its launch after up to two hops
    of its own — the liveness check on a session that turned out to be dead, and the
    death booking that follows it — and a switch landing in either of those windows
    would otherwise be read as "no switch happened": a live `sourcekit-lsp` started
    for a root nobody is looking at, which nothing reaps until the next switch or the
    quit. That window is microseconds wide and has no injectable seam, so it is
    guarded rather than staged; the *other* way into the fall-through — a request
    waiting on a launch the switch superseded — is deterministic and pinned by
    `testAFolderSwitchWhileARequestWaitsOnALaunchStartsNothingForTheOldRoot`.
    One token could not do both jobs:
    a `shutdownAll()` in the same turn would invalidate the very token the caller had
    just pinned.
    **Two teardowns, because a quit cannot `await`.** `shutdownAll()` is the polite
    path a folder switch uses: `didClose` every open document, then
    `shutdown`→`exit` each session, then await any launch still in flight so
    "nothing outlives this call" is true rather than likely. `terminateNow()` is the
    quit path — `willTerminateNotification` is the last thing AppKit posts, so a
    `Task` wrapping an async teardown would compile, never be picked up, and leave
    exactly the orphan `pgrep -fl sourcekit-lsp` checks for. It therefore reaches
    past the sessions (actors, hence unreachable without a hop) to the transports,
    whose `terminate()` is synchronous and idempotent by contract. That is why the
    workspace holds the transport beside each session, registered **before** the
    handshake — so a quit also kills a server still resolving a build system, which
    is the state a quit is likeliest to land in. For the same reason `shutdownAll()`
    does *not* empty `transports` alongside the maps it clears up front: each entry
    is dropped after that server's goodbye returns, so a quit landing while the
    folder switch is still politely stopping a server can still kill it. (Detail
    under `updateRegistry(_:)`, which shares the invariant.) `forget(_:for:)` guards
    that map with an identity check for `pendingLaunches`' reason: a launch that
    gives up resumes arbitrarily later and must not clear a *newer* transport filed
    under the same key.
    **`Process` is not in this file, and cannot be.** Transports arrive through
    `transportFactory`, which the app supplies and every test supplies as a scripted
    fake — the same seam `SymbolIndexModel` makes for tree-sitter extraction, for the
    same reason. The default factory throws, which is the honest answer rather than a
    stub that pretends. `delay` is injected too, so the restart tests assert D7's
    delays instead of sleeping for seven seconds.
    `canServe(_:)` is the question the router asks before spending a budget: a
    *policy* answer (is there a server for this language, in this root, that has not
    given up), which starts nothing and probes nothing. `prepare` returns `nil` —
    uniformly, for every failure — meaning "ask tree-sitter"; the caller does not
    distinguish the eight ways that can happen, because D7's fallback is per request
    and silent.
    URIs: `documentURI` is standardized but **not** symlink-resolved, because the
    server must be told the path the user opened; `rootKey` *is* canonical, so two
    spellings of one folder share one server; `path(of:isUnder:)` compares whole
    components through `CanonicalPath`.
    **`updateRegistry(_:)` swaps the registry while the app runs** (2b's D16), and
    is the one change that phase made to this machinery. 2a's registry was a `let`
    fixed at construction, which was enough while the only server was one `xcrun`
    finds; 2b installs servers *from Preferences*, and the whole promise of that
    feature is that opening a `.ts` file, accepting the download and getting
    semantic completion is one uninterrupted sequence — so `canServe` has to flip
    from `false` to `true` without a restart.
    It has to flip **both ways**, and that is the half with teeth: a description
    that is merely forgotten leaves its process running against a root nobody will
    ever ask it about again — the orphan `pgrep -fl node` finds after quitting. So
    a server that is gone *or changed* is shut down here, where "changed" is "not
    identical to what it was" (id, launch, arguments or initialization options)
    rather than "absent now", because a version bump is the same id pointing at a
    new executable path whose old directory the installer is about to delete. Its
    documents are `didClose`d first (D2) exactly as a folder switch does, its
    transport is dropped and its document state forgotten.
    Staleness is computed over **reachable** descriptions — the ones
    `description(for:)` actually answers, keyed by id — not over `descriptions`,
    because a description shadowed for every language it claims can never be
    launched again and its process should go with it.
    **Its D7 bookkeeping is cleared with it**, so a re-added server starts with a
    fresh budget of three restarts. "Never reset within a root" is about a server
    that keeps crashing on the same project; one the user has just removed and
    reinstalled is a *new* server on that project, and making someone relaunch the
    app to get a second chance after a bad download would be the silent failure D7
    exists to avoid rather than the one it prevents.
    **The epoch is deliberately not bumped.** That token supersedes every launch in
    flight, including ones for servers this update left untouched, and killing a
    healthy server's handshake because an unrelated one was installed is the
    opposite of what this method is for. A launch already running therefore
    completes and is unregistered and shut down afterwards, by id.
    **Every step of that cleanup is guarded by an identity check**, and so is the
    launch's own registration, because this is the one place two processes can
    exist for one key. Taking a launch out of `pendingLaunches` without stopping it
    means a Remove followed quickly by an Install can start a second server while
    the first is still handshaking; the *newer* one is the one everything must
    point at. So a finishing launch stands down rather than registering over a
    session that is already filed under its key, and the cleanup clears the
    session, the transport and the documents only while they are still the ones it
    is retiring. Clearing them unconditionally would drop the live server's
    transport out of `terminateNow()`'s reach — precisely the orphan this method
    exists to prevent, reintroduced by the method itself.
    **The transport's check is the transport's own identity, not the session's**
    (`forget(orphan.transport, for: key)`, which is why `LSPSession.transport` is
    readable). The two disagree in exactly one window, and it is reachable: a
    transport is registered *before* its handshake and a session filed only
    *after*, so a reinstall that is still handshaking already owns
    `transports[key]` while `sessions[key]` is still the withdrawn launch's. That
    is the one moment `sessions[key] === orphan` is true and the transport entry
    belongs to somebody else — and clearing it there leaves the reinstalled server
    serving requests with nothing for a quit to reach, the same orphan by a longer
    route. `testAReinstallStillHandshakingKeepsItsTransportWhenTheRemovalCleansUp`
    stages the two handshakes in that order.
    **A transport stays in `transports` until the process behind it is actually
    dead** — that is the invariant, and it holds for a live session and a pending
    launch alike, in `updateRegistry(_:)` and in `shutdownAll()`. `transports` is
    the only map `terminateNow()` reads, and *every* `await` this teardown makes
    runs against a process that is still alive: the handshake it waits out for a
    pending launch is the slowest thing this layer does, and the goodbye it waits
    out — for a live session and for that same launch once it finishes — runs a
    whole request budget. A withdrawn launch is therefore awaited **twice**, and
    the second wait is the one that is easy to lose: the obvious place to
    unregister is beside the session and the documents, which are cleared *before*
    the goodbye on purpose (a racing reader must find nothing), and putting the
    transport there too would hand the map back the window it exists to close.
    Emptying it on the way past would leave a quit inside any of those windows
    (`willTerminateNotification`, with no further run-loop turn to catch it) with
    nothing to terminate — the exact orphan both methods exist to prevent,
    reintroduced by them. So each entry is dropped after its own `await` returns,
    through `forget(_:for:)` so a launch that registered a *newer* transport under
    the same key keeps it. `shutdownAll()` needs no more than that for its
    in-flight launches: a superseded launch sees the epoch mismatch, terminates
    what it built and `forget`s it itself.
    `testAQuitDuringARemovalStillKillsTheServerThatWasHandshaking`,
    `testAQuitWhileAWithdrawnLaunchIsShuttingDownStillKillsIt`,
    `testAQuitWhileARemovedServerIsShuttingDownStillKillsIt` and
    `testTerminateNowKillsAServerAFolderSwitchIsStillShuttingDown` stage a quit
    inside each of the four windows.
    **The withdrawn launch's consumer is cancelled with it, in the same branch.**
    The up-front cancellation this method makes for every dead key runs *before*
    the handshake returns, and a launch it did not stop files itself and attaches
    a consumer afterwards — so the in-flight teardown cancels `notificationTasks`
    beside `sessions` and `documents`, in the same synchronous prefix, under the
    identity the branch already established (a consumer exists only beside a filed
    session, so `sessions[key] === orphan` is exactly the condition under which the
    entry is this launch's). Left attached it would outlive its session and speak
    the stream-finish clear for a key this same call already cleared;
    `testAWithdrawnInFlightLaunchClearsItsKeyExactlyOnce` pins the count.
    Neither generation moves either: a registry update is
    not a folder change, and a request in flight for a server that survived is
    still a request about the folder it was asked under. Every map a `prepare`
    reads is emptied *before* the first hop, `shutdownAll()`'s ordering applied to
    a subset — `transports` excepted, for the reason above, and harmlessly so
    since no reader consults it. An equal registry returns immediately.
    **The push channel** (D29/D31/D33) is this file's third ownership beside
    sessions and documents: one `@MainActor` consumer task per session, filed in
    `notificationTasks` beside it and cancelled with every teardown, iterating
    `session.notifications` from the moment the session is filed under its key —
    before the first request goes out, because a real server may push diagnostics
    for the `didOpen` well before the flush that carried it returns. `route(_:from:)`
    applies D31's gates as a conjunction, **cheapest first**: the URI
    must be a document **this**
    `(server, root)` currently holds (a closed file, another server's file, or an
    unopened one is noise), then the push must name the folder this
    workspace currently serves — a straggler from an old project's server in the
    window between `prepareForFolderChange` and the `shutdownAll()` it schedules
    would otherwise be routed, and, finding the model's bookkeeping cleared,
    *held*, onto whatever same-path file the next project syncs — and a present
    `version` must equal the version last
    flushed for it. A URI that does not parse as a `URL` is dropped first, at the
    one boundary where the round-trip happens — and the parse comes first for a
    reason: this is the only place a **server-supplied** URI meets a key we
    generated, so the lookup tries the server's own spelling and then *ours* for
    the same parsed URL (`documentURI(for:)`, the very function that minted the
    keys). A server is free to re-spell what it was handed — a different but
    equivalent percent-encoding is the ordinary case — and a raw string compare
    alone would drop every diagnostic for that file, silently, for the whole
    session, with nothing to notice it by. That ordering is about **cost**, not
    meaning: a server finishing a workspace-wide check publishes one notification
    per file it knows, nearly all of them for files no tab holds, and the two
    gates that used to run before the membership test are the expensive pair —
    `rootKey(for:)` resolves symlinks on the file system and `decoded(as:)`
    re-encodes and re-parses the whole diagnostics array, both on the main actor
    the editor types on. So the URI is read straight off the raw parameters
    (`params["uri"]`) and the body is decoded only once the push is known to name
    a document we hold. A push passing every gate is mapped
    against `documents[uri].text` —
    the text the *server was told*, not the live buffer; reconciling the editor's
    later edits is `DiagnosticShift`'s job downstream, never a remap here — one
    line-start scan per push, and the survivors go to the sink as an
    `LSPDiagnosticEvent.published`. Every other notification is dropped exactly
    as before. The output side is `var onDiagnostics: ((LSPDiagnosticEvent) ->
    Void)?`, whose cases are `published(url:serverID:root:version:diagnostics:)`
    and the clears — because a stale squiggle is only half the failure mode; the
    other half is diagnostics outliving their server. So **every teardown path
    emits its key's clear** (D33): `noteDeath`, `shutdownAll()`,
    `terminateNow()`, `updateRegistry(_:)`'s removal branch on both its halves,
    each `unavailable.insert` site, `didClose(url:)` per document, and — the one
    case no deliberate path covers — the consumer task's own exit when the stream
    finishes under it, which is how an externally killed server is noticed without
    touching D7's counters (`prepare` still owns crash *detection*). The
    stream-finish clear checks that no replacement session already owns the key,
    so a restarted server's fresh pushes are not wiped by their dead predecessor's
    goodbye (in practice a backstop — replacement sites cancel the incumbent
    consumer first; see D33's reachability note). The sink is called synchronously
    on the main actor; what accepts or drops the event next is `DiagnosticsModel`'s
    gate, below.
    **A reader, never a writer** (D10).

  - `CompletionEditPlan.swift` — the pure rule auto-import is applied by, so the
    editor's job shrinks to "raise the programmatic-edit flag, open one undo group,
    apply `edits` in order, set the selection to `caretOffset`".
    `CompletionEdit` is one buffer edit in **buffer coordinates** (UTF-16,
    absolute) — the LSP conversion happens once, in the provider, so nothing
    downstream of the seam has to know what a line is. **An edit says what it is
    *for*, because the geometry cannot**: an `import` inserted at offset 0 and a
    symbol completed at offset 0 of an empty file are geometrically identical, and
    D4's "caret after the symbol, never at the import" needs to tell them apart. So
    each edit carries a `Role` — exactly one `.primary` per plan; zero or two is a
    rejection.
    `shifted(afterReplacingTypedWord:withLength:)` re-expresses one edit against a
    buffer in which the typed word has already become something of a different
    length. It exists because AppKit writes the buffer before the user has chosen
    anything (`insertCompletion(…, isFinal: false)` per arrow key) and because D4's
    late auto-import lands on top of an insertion that already happened. Only three
    shapes are possible, since a plan's edits never overlap and the primary one
    covers the typed word entirely: an edit wholly before it is untouched, one
    wholly after it slides, and the primary edit — the only one that can span the
    boundary — grows or shrinks by the difference. **The primary edit is recognised
    by its role, not by its geometry**, and that is what makes an empty typed word
    work: a member list opened by a bare `.` replaces nothing, so the word's start,
    its end and the caret are one number and the primary edit is a zero-length
    insertion sitting on it — geometrically indistinguishable from an edit "wholly
    after the word", and read as one it slid past the preview it was supposed to
    replace, `make` rejected the plan for `primaryEditMissesTypedWord`, and the
    item's `import` was silently dropped on exactly the completion kind that has no
    prefix. It is a decision, not glue, so it lives in Core with its own tests.
    `make(edits:in:replacing:typed:)` returns the ordered application list and the
    resulting caret, or a typed `Rejection`. **Edits are ordered strictly
    last-to-first**, the same rule `TextSearch`'s Replace All follows and for the
    same reason: each edit then lies entirely before every edit already applied, so
    no pending offset is invalidated and the caller needs no offset arithmetic.
    **Staleness is checked against the buffer, not assumed**: `typed` is what the
    typed word's range contained when the request was made, and it is compared to
    what stands there now. A list is computed behind a debounce and committed a
    keystroke later, so typing, deleting and undoing between the two are ordinary —
    and all three produce offsets that now name someone else's characters. One
    substring catches every one of them, the same per-item re-check
    `ProjectSearchModel` does before it replaces.
    **The primary edit must *cover* the typed word.** A server is free to answer
    with a range wider than the client's prefix (it decides what the completion
    replaces, and for a member access that can reach back past the dot), but one that
    reaches less far would leave the typed characters in the buffer with the
    completion appended — `GreGreeter` — so it is refused.
    **Two edits starting at the same offset are refused even when neither covers a
    character.** They do not overlap geometrically, but nothing in the spec says
    which comes first, and a zero-length insertion at the start of a replaced range
    could land on either side of it. An insertion at the *end* of a replaced range
    has a defined order and is allowed; both cases have a test.
    Rejection is a **safe** outcome, not an error worth surfacing: the editor falls
    back to AppKit's own insertion of the plain text and loses only the auto-import.
    `displayText(forTypedWordStartingAt:in:)` is the second question this file
    answers about how an edit relates to the typed word, and it lives here for
    that reason rather than at the seam it feeds: given the typed word's start and
    the buffer the edit was computed against, it answers what a popup row should
    read — `newText` minus a head that re-writes, **verbatim in UTF-16**, the
    characters standing between `range.location` and the typed word's start, and
    the full `newText` otherwise. UTF-16 units literally, not `String` equality,
    because "the same characters the buffer holds" here means the same code units:
    the head is not re-typed, it is left standing.
    That head-dropping is the *only* difference allowed, and the reason is that
    the shown string is not only shown — AppKit previews it over the typed word as
    the user arrows and inserts it there itself when `make` rejects the plan as
    stale, so whenever this rule *drops* a head those two compose exactly the
    buffer the plan would have.
    (For tsserver's dot shape today's fallback writes `greeter..greet`, so the
    rule corrects that path rather than merely prettifying a row.)
    **The guarantee runs one way, and that is not an oversight.** A string the
    rule *keeps* promises nothing about the fallback: `?.greet` inserted over the
    typed word composes `greeter.?.greet`. Nor does a dropped head help when the
    server's range reaches past the caret — `make` demands only that the primary
    edit reach *at least* the typed word's end, so the characters beyond it stay
    standing. Both are limits of the fallback path itself, which can only ever
    replace the typed word, and no choice of display string repairs either; they
    are the reason the rule refuses to shorten in those cases rather than
    evidence that it should shorten more. Hence the
    guards: `?.greet` over the same range keeps its full spelling because `?` is
    not what stands there, a `newText` that *is* the head keeps it because an
    empty row is not a row, and no gap at all (`range.location` == the typed
    word's start, the sourcekit-lsp member shape) leaves the string untouched.
    **Only the primary edit is ever a row** — an accompanying `import` is inserted
    whole and never displayed — so a non-primary edit answers `newText` unchanged.

  - `HoverContent.swift` — everything a hover popover draws, and the one place
    LSP's markup is interpreted (D25). Two value types and a reader, in one file
    for the same reason `CompletionEditPlan` is one: the *rule* and the type whose
    invariants it establishes belong together.
    `HoverSegment` is a run of text plus what it is — `.code(language:)` or
    `.prose` — and that distinction is the only one a renderer acts on, which is
    why this is not a single string: a type signature drawn in the interface font,
    its `<`/`>` read as markup and its indentation collapsed, is not a type
    signature, and a paragraph of documentation drawn in the code font is a wall.
    A `nil` language means "monospaced, uncoloured", never "guess".
    `HoverContent` is an ordered list of those plus `isTruncated`, and **it knows
    nothing about LSP**: the view layer needs no protocol vocabulary to draw an
    answer, and a second source of hover text would produce the same value. Its
    initializer is failable and that is the decision: segments carrying only
    whitespace are dropped, and content left with none is `nil` rather than a
    `HoverContent` with no segments. **There is no empty popover** (D25), so
    "show it if there is one" is the only rule a caller needs and an empty one
    cannot be drawn by accident. The same initializer strips each kept segment's
    blank first and last *lines*, which makes `HoverSegment.text`'s stated shape
    true of every segment rather than only of the ones `HoverMarkup` built (whose
    `codeBlock`/`proseBlock` already did it, so this is a no-op on the LSP path).
    That is what `truncated` stands on: it keeps a *prefix* of a segment's lines,
    so a segment whose first line were blank could be cut down to whitespace —
    a popover drawing an ellipsis and no answer, which is the forbidden state
    arriving by the back door. Stripped line-wise, never off the joined string,
    for `proseBlock`'s reason: trimming the join takes the first line's
    indentation with it and leaves every following line's in place.
    It owns the feature's **two constants**, here rather than in the view for the
    reason every other rule is here: `dwellDelay` (0.35 s — the difference between
    "hovering tells you the type" and "moving the mouse across a file fires a
    request per identifier"), `maximumLineCount` (20), `maximumLineLength`
    (2 000 characters), `maximumLineUTF8Length` (16 000 bytes) and
    `maximumInterpretedLineCount` (200). `truncated(toLineCount:lineLength:)` is the cap as pure, idempotent
    arithmetic: it keeps whole segments while they fit, cuts the one that straddles
    the line limit *keeping its kind and language* (half a code block is still
    code), clips every kept line to the length limit on a `Character` boundary (so
    no cut can halve a grapheme), and reports that it cut. Either limit below one
    is read as one — a caller asking for a popover is not asking for a smaller
    answer but for a different and forbidden one. For the same reason the cap
    yields before the invariant does: a length limit small enough to leave nothing
    but a first line's indentation returns the content *whole*, because an answer
    too big for the cap is still an answer and an empty one is not. **Long content truncates; it
    never scrolls** (D26), and the arithmetic lives here because the renderer's
    only remaining job is to draw a marker when `isTruncated` says so.
    **The cap has two dimensions and both are load-bearing.** A line count bounds
    nothing a renderer can use: twenty lines can be twenty megabytes, the answer's
    size is a language server's to choose (`LSPFraming` will carry 64 MB), and the
    panel measures and lays that string out *synchronously on the main thread* from
    an event that fires whenever the pointer stops moving. So the length cap is
    what makes "at most twenty lines" also mean "at most a bounded amount of work",
    and it is set far past anything a 520 pt panel can show precisely so that it
    never fires on a real signature or paragraph — it is a hang guard, not a
    display rule.
    **The cap may not cost what the cap prevents**, and that is why the two
    dimensions are applied in two different places. The line *count* is the display
    rule, so `truncated(toLineCount:)` is the renderer's call. The line *length* is
    the hang guard, so it is established by the **checking initializer** — which is
    to say wherever a `HoverContent` is *built*, and on the LSP path that is
    `LSPIntelligenceProvider.hover`, a `nonisolated async` method and therefore off
    the main thread. A clip there sets `isTruncated` (content was lost; the marker
    is how the popover says so) and happens *before* the blank edge lines go, so
    the degenerate line — three thousand spaces and then a character — cannot clip
    down to whitespace and survive as a segment with nothing to draw. That makes
    `HoverSegment.text`'s stated shape include "no line longer than
    `maximumLineLength`", and every later reader — `truncated`, `lineCount`, the
    panel — walks text that is already bounded. Doing it the other way round is the
    bug this replaced: a cap applied for the first time in `truncated` still has to
    *find* the end of the megabyte line before it can drop it, on the main thread,
    from a mouse-moved event — bounded allocation over unbounded work.
    **The same argument reaches one level further back, and that is where the cap
    is actually applied: to the server's string, before `HoverMarkup` interprets
    it.** The checking initializer is off the main thread, but it sees the parse's
    *output*, and the parse is the pass that costs the size of the answer — worse
    than linearly. `HoverMarkup.inline(_:)` rescans to the end of the line from
    every `[` that never finds a target, so a line of unmatched openers is
    quadratic: 80 KB of `[a](` spent eighteen seconds to produce two thousand
    characters that the cap downstream then threw away, on the cooperative pool,
    with no suspension point for `RoutingIntelligenceProvider`'s 1.5 s budget to
    cancel at — the caller gives up and the thread keeps spinning. So
    `init?(hoverElements:)` runs `clippedLines(of:)` on each element first and
    passes the resulting `isTruncated` down; the checking initializer's own clip
    stays (it is the rule for every other caller) and is simply a no-op on this
    path. **A label's nesting is bounded for the same reason and separately**: a
    link label is degraded by calling `inline` on it *recursively*, and the depth
    is the server's to choose, so a few hundred levels of `[x](u)` overflowed a
    cooperative-pool stack and killed the process — 2.5 KB of input, well inside
    every length cap. Past `maximumLabelNesting` (16, past anything a hover answer
    writes) the `[` is written literally and the scan moves on one character,
    which is the answer an unmatched bracket already got: unmatched markup is text.
    **Where each `[` closes is precomputed**, in one stack pass over the line
    (`closingBrackets(in:)`), rather than matched on demand — and that is a third
    bound rather than a tidier spelling of the second. An on-demand match walks to
    the end of the line whenever the bracket turns out to be *unmatched*, and an
    unmatched bracket is the common case in exactly the prose this reader exists
    for (`[]byte`, `map[string]int`, `data[index]`). That is quadratic per line,
    so the line-count cap *multiplied* the residue instead of closing it: 200
    lines of 2 000 brackets — inside every cap above — measured **eight and a half
    seconds**, spent on a cooperative-pool thread, past the only cancellation
    check, on a result the request budget had already thrown away. The pass makes
    the work linear in the text, which is what makes the caps mean what they say.
    **The length cap is itself two caps, in characters and in UTF-8 bytes, and the
    byte one is what closes the guard.** `maximumLineLength` counts `Character`s, a
    `Character` is an extended grapheme cluster, and a cluster has no size limit:
    a letter followed by a million combining marks is *one* character, so a
    character cap of any size passes that line through whole and the megabyte hang
    arrives through the guard meant to stop it. `maximumLineUTF8Length` is
    therefore stated in the unit the layout actually costs — eight bytes per
    character, twice UTF-8's maximum for a single scalar, so a line can only reach
    it by not being text. The clip walks characters and checks the byte budget
    *before* keeping each one, which is what makes the oversized cluster a
    truncation rather than an exception to the cap: it is dropped whole (never
    halved — the cut stays on a `Character` boundary), and content that was nothing
    but such a cluster is then no content at all, the no-empty-popover rule reached
    from the other end. Ordinary text never meets any of this: a line whose whole
    UTF-8 size fits the *character* cap can break neither cap, and that check is
    the first thing the clip does.
    **The third side of the guard is the line *count*, and the two length caps
    leave it open**: they bound what a line costs, not how many arrive. Four
    hundred thousand short lines pass both — every one is far inside either cap —
    and still cost seconds in `HoverMarkup` before `truncated(toLineCount:)`
    throws all but twenty away, off the main thread but on the same cooperative
    pool completions, definitions and the index walk share, and with the whole
    attempt's budget already expired. `maximumInterpretedLineCount` closes it in
    the same place and the same pass as the other two, and is spent as **one
    budget across the elements together**: the payload carries an array, so a
    per-element bound is no bound at all. Ten times what the popover draws, so
    the guard is never what cuts a real answer — the lines it counts are the
    server's, before blank ones and fences fold away — and an element cut for
    want of budget, or one never read at all, marks the answer truncated like any
    other loss. `HoverMarkup.lines(of:limit:)` is what makes the bound cost less
    than what it prevents: it scans the UTF-8 view for `\n`/`\r` (either byte is
    one break, `\r\n` is one break, and the lines come back through
    `String(decoding:as:)` because the `\n` of a `\r\n` pair is not a `Character`
    boundary), stops when the budget runs out, and so never copies the whole
    string — which the two `replacingOccurrences` passes it replaced did twice
    over. A line-count guard that first materializes every line has already paid
    what it exists to save.
    Within that, `truncated` still reads each segment line by line (`cappedLines`)
    rather than `segment.lines` + `prefix`, so it materializes only what it keeps
    and walks only as far as the line budget reaches. Line ends are found on the
    UTF-8 view (a newline is one byte no multi-byte sequence can contain, so the
    search is a byte scan rather than grapheme breaking over text about to be
    discarded); the clip itself stays on the `Character` view, where the
    no-halved-grapheme promise lives. The renderer's whole cost is therefore at
    most `maximumLineCount` × `maximumLineLength` characters, whatever the server
    sent.
    `HoverContent(_ response:)` / `init?(hoverElements:)` are the construction
    from a decoded payload: each element becomes segments, in the order the server
    wrote them, so `[{language: "swift", value: "func f()"}, "Does a thing."]`
    stays a code segment followed by a prose one — merging them is exactly the
    mistake the two kinds exist to prevent.
    `HoverMarkup` is the reader, and is **not a Markdown implementation and not
    trying to be**. Hover answers are a narrow dialect — a fenced signature, a
    paragraph, a list, the odd link — and the invariant that matters is that
    **what it cannot render is degraded rather than shown raw**: a `**` left
    standing in a type signature reads as an error in the *code*, not as a
    limitation of the popover. The two markup kinds are read differently, which is
    the whole reason the server is asked to declare one: `markdown` is
    interpreted, `plaintext` is **not** — its asterisks and backticks are the
    text, and stripping them would corrupt a signature the server took care to
    send unformatted. Both are normalized for whitespace.
    Block structure first: a fence (three or more backticks or tildes, up to three
    spaces of indent, the info string's first word as the language) opens a code
    segment and the prose before it is flushed; an *unterminated* fence takes the
    rest of the element as code, which is CommonMark's rule and also the forgiving
    one, since a server that forgot a closing fence meant everything after it to
    be a signature. A backtick fence whose info string contains a backtick is not
    a fence at all but an inline code span on its own line.
    Then per line: horizontal rules go, headings lose their `#` — a *closing* run
    only when whitespace precedes it, CommonMark's rule and the one that keeps
    `# Learn C#` from becoming `Learn C` — `-`/`*`/`+` bullets
    become `•` (ordered `1.` markers are left alone — they already read as a list
    and their numbers carry meaning a bullet would throw away), and inline markup
    is stripped in **one left-to-right pass** rather than by a series of
    replacements, because order is the whole of it: a code span's contents are
    kept verbatim (`` `a*b*c` `` keeps its asterisks while `*emphasis*` loses
    them), a link or image keeps its text/alt and loses its URL, and a backslash
    escape yields the character it escaped. An unclosed code span leaves its
    backticks standing rather than eating the line.
    **A `[…]` is a link label only when a `(url)` destination actually follows
    it**, and otherwise the brackets are written out as the text they are. This is
    the same rule as the unclosed emphasis run below and it is load-bearing for
    the same reason: reading every balanced bracket pair as a label answers `byte`
    for `[]byte`, `mapstringint` for `map[string]int` and `T; N` for `[T; N]`,
    which is how Go and Rust spell *types* in exactly the unfenced prose this
    normalizer sees. A wrong name, not an unformatted one.
    **Nor is an *argument list* a destination**, which is the same rule's third
    form and the one that bites hardest. A balanced `(…)` after a balanced `[…]`
    is CommonMark's inline link *and* is how three languages spell a call on a
    subscript or on a type argument list, so consuming it whole answered `Int` for
    Swift's `[Int]()`, `String` for `[String](repeating: "a", count: 3)` and
    `func MapK comparable, V any []K` for a Go generic. The test is CommonMark's
    own grammar rather than a new invention — a destination is one run of
    non-whitespace characters (or an angle-bracketed one) plus an optional
    *quoted* title, so an argument list, carrying unquoted whitespace past its
    first word, is not one — with the single narrowing that an **empty**
    destination is refused where the spec allows it: `[X]()` links nowhere, so
    reading it as a link buys nothing and it is exactly how Swift spells an empty
    array literal. What is left ambiguous is left: `a[0](b)` and
    `Dict[str, int](x)` still read as links, because narrowing past this would
    have to reject a destination for being *short*, which is what a real relative
    link in a doc comment looks like.
    **A reference target is not read either** — `[label][ref]` and the shortcut
    `[Vec]` both keep their brackets — which is where the rule stops following
    CommonMark rather than merely narrowing it. `a[i][j]` is a doubly-indexed
    expression in every language a server answers for *and* is character-for-
    character CommonMark's collapsed-reference syntax, so the two cannot both be
    honoured, and honouring the markup answers `ai`. The trade is one-sided: a
    reference link resolves against a `[ref]: url` definition, a hover answer is a
    fragment with no document for one to live in, so no server can send a
    reference that would have resolved anyway.
    **`<`…`>` is dropped only against an allow-list of HTML element names**, and
    the attribute list is *walked* rather than skipped to the next `>`. Both
    halves are deliberate departures from CommonMark, in the one direction this
    popover can afford. By the spec `<T>` and `<u8>` are perfectly valid raw HTML
    — and they are also exactly how rust-analyzer, gopls and sourcekit-lsp spell a
    generic in the unfenced prose beside a signature, so a spec-faithful reader
    answers `Vec` where the server said `Vec<u8>`: wrong, not merely plain. The
    walk is the other half: `Compare a<b and x<y>z` opens with something
    tag-shaped, and a scan to the nearest `>` deletes the clause between them,
    where an attribute walk rejects the `<` inside `x<y` and leaves the sentence
    alone. Names are matched case-sensitively for the same reason the list exists
    — markup is written lowercase and type parameters capitalised, so `<BR>`
    surviving as text is far cheaper than `Box<B>` losing its parameter.
    **An attribute must carry a value**, where HTML allows a bare boolean one, and
    that is the walk's third half: `a<b and b>c` is a well-formed `<b>` element
    with two valueless attributes, so the walk alone accepted it and deleted the
    comparison between the angle brackets — and the single-letter names on the
    allow-list are precisely the ones that collide with variable names. A server
    that really writes `<details open>` loses its markup to literal text, which is
    the cheap direction.
    **`<br>` is the one element that leaves something behind**: a space. Its whole
    meaning is a separator, so dropping it like the rest joins the words either
    side (`one<br>two` → `onetwo`), which reads as a typo rather than as text with
    its formatting removed. The popover's prose wraps at the panel width, so the
    *line* the tag asked for cannot be honoured anyway; the gap can, and runs are
    collapsed from both sides so `one <br> two` gains nothing.
    **HTML entities are not decoded** — `&lt;` reaches the popover spelled that
    way. A known limit rather than an oversight: it is the degraded-not-wrong
    direction, and decoding would have to guess whether an `&amp;` in prose about
    C is markup or the operator.
    **Emphasis is paired, not merely flanked.** What a run touches decides what it
    *may* be — non-whitespace on the right may open, on the left may close, none
    on either side is arithmetic (`a * b`) and stays, and `_` may not do both at
    once, which is what leaves `some_identifier_name` spelled the way the code
    spells it, and **a `_` run of two or more may do neither** — but a run that
    *may* open is markup only once something closes it.
    That last clause is a second deliberate departure, made for the allow-list's
    reason. The intra-word rule cannot reach a dunder: `__init__`'s runs *flank*
    the word rather than sit inside it, so CommonMark reads them as strong
    emphasis and the popover names the symbol `init` — wrong, not merely plain,
    and pervasive in the docstring prose a Python server attaches to a hover
    (`__init__`, `__name__`, `__all__`). Its worst shape is `See __str__ and
    __repr__.`, where the spec renames only the first of two identical names. The
    trade is one-sided: every server writes bold as `**bold**`, which still
    degrades, so refusing the `__bold__` spelling costs an occasional literal pair
    of underscores — unformatted rather than misnamed, the direction this reader
    picks every time.
    An opener the line never closes is written back literally, which is CommonMark's
    reading and the difference between `w*h`, `*ptr` and `_private` reaching the
    popover as themselves and reaching it as `wh`, `ptr` and `private`. This is why
    the pass assembles pieces rather than one appended string: a delimiter cannot
    be judged when it is read, so its piece is written empty and rewritten if the
    promise of a closer is not kept.
    Whitespace last: code blocks lose trailing whitespace per line and blank lines
    at both ends while **every line's leading indentation stays** (it is the code);
    prose is stripped **the same way, line-wise**, and additionally collapses runs
    of blank lines to one, since a server that
    separated two sentences with four newlines meant a paragraph break rather than
    a hole in the popover. Line-wise is the load-bearing word: trimming the *joined*
    block instead — which is what `proseBlock` used to do — takes the first line's
    indentation away and leaves every following line's, so an indented plaintext
    signature (the shape a server with no markdown renderer sends) arrives with its
    head shifted left against its body. `degraded(_:)` keeps each line's indent to
    preserve nested lists, and this is the one place that was disagreeing with it.
    A line that degrades to nothing becomes a blank line and
    is then collapsed away, so a lone `---` between two paragraphs leaves one
    separating blank line rather than a gap or a stray glyph.

  - `RenameEditPlan.swift` — a server's `WorkspaceEdit` turned into something this
    editor can *verify* and *apply*, and nothing else. `CompletionEditPlan`'s
    position in the stack and `CompletionEditPlan`'s reason for existing: the rule
    is pure, so the whole rename decision is unit-tested and the disk writes stay in
    the one place that holds the writer bracket. **It reads no file and writes
    none** — the texts arrive as a closure the caller answers from the open buffers
    first and the disk second, and what comes back is per-file replacements.
    **Two moments, two methods, on purpose.** `make(from:root:texts:)` builds
    the plan against the texts in hand *before* the bracket is raised, which is
    where every refusal happens — nothing captured, nothing suspended, nothing to
    undo. `apply(bufferText:fileService:)` re-reads *inside* the bracket, after the
    Local History capture, and verifies every file before writing any; that
    verification pass is the last moment anything can abort. It is deliberately not
    a `verify` method of its own — a separate call would be a second read of the
    same texts with a window between it and the write in which the thing verified
    could change again, and the pass `apply` already runs closes exactly that
    window. Both moments check `holds`, and that is not redundant: `make`'s texts
    may be minutes old by the time `apply` runs, and `apply` is the one that must
    not write into a file that moved.
    **Five named refusals, each fatal to the whole rename** (`RenameRefusal`):
    `notAFile` (a document URI that is not a file URL), `outsideRoot` (a file
    outside the opened project — compared **canonically**, because a server
    answering `/private/tmp/…` about a project opened as `/tmp/…` is naming a file
    that *is* inside the root and a lexical prefix test would refuse every such
    project), `unreadable`, `unmappable` and `overlapping`. All-or-nothing is the
    point: a rename applied to four files out of five leaves a project that no
    longer compiles and no single step to undo, which is strictly worse than a
    rename that did not happen. They are separate cases rather than one string
    because they are not equally surprising — only `unmappable` and `unreadable`
    are worth putting a file name in front of a user, and a caller cannot tell
    those apart from a rendered sentence.
    **`unmappable` is where this file disagrees with `LSPPositionMap` on purpose.**
    That type *clamps* an impossible position to the nearest real one, which is
    right for every other caller because they are all navigating and the nearest
    real position beats refusing to move. A write is the one case where the clamp
    *is* the bug — it would silently move the edit onto text the server never meant
    — so each offset is round-tripped back into a position and refused when what
    comes back differs from what went in. That is the clamp, detected rather than
    re-implemented.
    **`expectedText` is the whole staleness story** (D37). A rename's request, its
    answer and its application are three moments with awaits between them, and in
    them a git operation, another editor or the user's own typing can move the text
    under a range the server computed against something else. Each `RenameEdit`
    therefore carries what its range held when the plan was built, and `apply`
    compares the bytes — the first mismatch answers `.stale(URL)` and the rename is
    over. There is no count of stale files, because the answer to "which ones"
    changes nothing a caller does.
    **What the plan is built *against* is what makes that comparison mean
    anything**, and it is the app's half of D37: `PisakaApp.applyRename` builds the
    plan against **the text the server was given, for every file, and against a live
    buffer for none**. The dialog is modal but the round trip after it is not, so a
    keystroke during it moves every offset after the caret; planning against the
    current buffer would map the server's coordinates onto text they were never
    computed for and then record whatever bytes sit there as `expectedText`, a
    verification that passes by construction. Planning against what the server was
    told turns that case into the honest one: `apply` re-reads the live buffer,
    `holds` fails, and the command says the file changed and writes nothing.
    The *requesting* file's copy of that text is `request.text` — the buffer as it
    was when the question was asked, which is definitionally what
    `LSPIntelligenceProvider` prepared the document with. Every **other** file in
    the answer is one nobody prepared, and its copy is
    `LSPWorkspace.lastSentTexts()`: a background tab typed in less than the 400 ms
    document-sync debounce ago (D30) is a buffer the server has never seen, and
    mapping its references onto that buffer is the same hazard one file further
    out — with no undo behind it, because a tab that is not the displayed one is
    rewritten through `WorkspaceModel.replaceText` (decision 5). That snapshot is
    taken by `renameSymbol` **before the rename request is sent** and handed down
    to `applyRename`, never read when the answer comes back: a server reads
    notifications in order, so the earlier map is what it answered against, while
    the later one can already carry a tab typed in *during* the round trip and
    pushed on the debounce after the answer was computed — the exact text that
    would make `expectedText` agree with the live buffer and let the wrong spans
    through. Read early the map can only be *older* than the server's baseline,
    and `holds` refuses that; read late it can be newer, and `holds` cannot see
    it. `stillHolds`
    cannot see either case: it compares the *prepared* document's version and
    nothing else, so both halves are closed here instead, together. A file
    `lastSentTexts()` does not name is a file no server holds open, which means the
    server answered about the bytes on **disk** — so the fallback is `FileService`
    and never `WorkspaceModel`, and a dirty tab over such a file ends in the stale
    refusal rather than in a write.
    Edits are grouped by **canonical path** and sorted together — `documentChanges`
    is a list, so one document may appear twice, and sorting two entries separately
    would produce a descending pair no back-to-front application can survive — then
    ordered ascending and checked for overlap (including the two-zero-length-edits-
    at-one-offset case, which the ascending test cannot see and which can only be a
    server contradicting itself). The result is `SaveTransformPlan`'s shape, and
    that is deliberate rather than convenient: it is literally the same thing —
    ascending non-overlapping replacements, the text they produce, and one
    arithmetic for moving a caret, a selection and a scroll anchor through them — so
    the displayed tab's application path is the one the app already has.
    **`apply(bufferText:fileService:)` is the one method here that touches the
    disk**, and it is where the rename's atomicity lives: *every* file is read and
    verified before *any* file is written. It hands back a `RenameApplication`
    splitting the work in two, which is decision 5 rather than an implementation
    detail — a file no tab holds is disk (the engine writes it; there is no undo for
    it anywhere but Local History), a file a tab holds is a buffer (rewriting it on
    disk under an open editor would leave the tab showing old text over new bytes),
    so the engine writes nothing for it and the app rewrites the buffer through
    `SaveTransformController`. A file that cannot be *read* here is reported as
    `.stale` rather than as a separate failure: it was readable when the plan was
    built, so whatever happened to it since is exactly what staleness refuses. A
    disk write that *throws* is the one thing that cannot be undone by refusing —
    the files before it have changed — so it is reported as `writeFailure` rather
    than swallowed or dressed up as an abort, and the app says which file and where
    the "Before Rename" revisions are.
    `RenameNameRule` lives here too, and in Core rather than in the dialog because
    it is a decision and not a widget: a new name must satisfy
    `IdentifierScanner.isIdentifier(_:)` — the very rule that decided what the caret
    was pointing at, so a name this accepts is one the editor can resolve back to a
    symbol — and must differ from the old one. Blank input is deliberately *not* a
    refusal: an empty field is incomplete input rather than a mistake, and the
    dialog disables OK for it without saying anything.
    **Out of scope** (follow-ups): a rename *preview* (a list of the edits with
    per-file opt-out before anything is written), `textDocument/prepareRename` (the
    server's own opinion on whether the caret names something renameable, and its
    suggested placeholder), and cross-file undo — the three things that would make
    a rename a single reversible act rather than one undoable tab plus a Local
    History revision per file.

  - `LSPIntelligenceProvider.swift` — the `CodeIntelligenceProviding`
    implementation that answers from a server, and the one place the two coordinate
    systems meet. Three rules run through it.
    **No answer is better than a guessed one.** Every uncertainty — no file URL, no
    language, no caret offset, no server, a request that failed, a target file that
    cannot be read — returns an empty result, which the router reads as "ask
    tree-sitter". None of it is logged, alerted or remembered.
    **The server's ranking is the ranking** (D6): items ordered by `sortText ??
    label` with the server's own array order preserved on ties (the enumerated index
    is carried as the last sort key rather than trusting `sorted(by:)` to be
    stable), then only hygiene — drop the item that would expand as a snippet, drop
    the item identical to what was typed, collapse
    duplicates by inserted text (first wins), cap at
    `SymbolIntelligenceProvider.defaultCompletionLimit`.
    **The prefix match decides one thing: which half the cap reaches first.**
    sourcekit-lsp, tsserver and pyright answer a prefix with the items that answer
    it, so this loop asked nothing for four phases; `yaml-language-server` answers
    the caret's entire schema property set regardless of the prefix (93 items in a
    compose service, identical to the empty-prefix answer), so the cap alone
    decides what is seen and `image` falls below an alphabetical 30. The one
    matcher every other candidate source uses — `FuzzyMatch.matches(_:query:)` over
    `filterText ?? label`, the spec's own filtering key, never the inserted text
    (a YAML object property inserts `services:\n  `) — now partitions the list ahead of the
    sort. It is neither a filter nor a ranking: nothing the server sent is dropped
    for failing it (its own matching may legitimately be looser — the recorded
    transcript answers `Gree` with `VM_MEMORY_MALLOC_LARGE_REUSED`), and inside
    each half `sortText` and the server's array order still decide. An empty prefix
    (the bare-dot member case) puts everything in one half.
    **The snippet drop is enforcement, not tidiness.** D5 advertises
    `snippetSupport: false`, but a client capability is a *request*: a server that
    ignores it answers with `insertTextFormat: 2` and a `newText` full of
    `${1:…}` placeholders, and a completion item is the one thing in this layer
    whose result is written to the user's file rather than merely displayed. So the
    field is read, not just decoded — but it is read *with* the text it labels,
    because the flag alone is not a fact either way: an item is dropped when it
    claims snippet format **and** `LSPCompletionItem.carriesSnippetSyntax` (a `$`
    or a `\\`, the whole grammar's two entry points). Absent means plain text (the
    spec's default) and is kept. `yaml-language-server` is why the second half
    exists: it marks every property completion `Snippet` and never reads
    `snippetSupport`, so a flag-only test would throw away `services:\n  ` —
    literal text under either format — and with it every completion the server was
    downloaded for. No answer is still better than a guessed one; a
    placeholder-free snippet is not a guess.
    **Multi-line inserted text is re-indented to the caret's line.** A server
    that answers with more than one line spells the lines after the first relative
    to the *item*, not to the buffer, and expects the client to add the current
    indentation back — LSP's `insertTextMode.adjustIndentation`.
    `yaml-language-server` is the case in hand and it is not a corner one: an
    object-valued schema property inserts `deploy:\n  `, the same eleven
    characters at every nesting depth, so writing it verbatim four columns in
    leaves the caret at column 2 and what the user types next becomes a sibling of
    the grandparent key — in a document that still parses.
    `indentingContinuationLines(of:forInsertionAt:in:lineStarts:)` prefixes the
    insertion line's own leading whitespace (measured *up to* the insertion point,
    per the spec's wording) to every following non-empty line, leaves the first
    line and each line's own relative indent alone, and returns single-line text
    identical — the test that comes first, because this runs per item per
    keystroke. It is applied before the drop rules and the dedup, so the row, the
    dedup key and the primary edit are one string; `resolveEdits(for:)` applies
    the same rule, since an item whose edits arrive late inserts the same text.
    Splitting on `\n` alone is complete: a `\r\n` splits into `…\r` plus the next
    line, and the prefix lands after the `\n` either way — **but the test that
    gets there is over scalars, not `Character`s**, because `\r\n` is a single
    grapheme that is not `"\n"`: a `contains("\n")` grapheme test answers `false`
    for exactly the CRLF text the splitter goes on to split, handing back the
    unindented insertion the rule exists to prevent. The guard and the split must
    agree on what a newline is. That split also decides what *empty* looks like:
    each line's terminating `\r` lands at the end of the previous component, so a
    blank CRLF line arrives as `"\r"` and an `isEmpty` test would indent it —
    writing trailing whitespace into a line the server left empty. The
    "stays empty" rule is `isBlank(_:)` (`""` or `"\r"`) for that reason.
    Both call sites ask through `insertedText(of:forInsertionAt:in:lineStarts:)`,
    which is where the one exception lives: an item carrying
    **`insertTextMode: 1` (`asIs`)** is inserted verbatim, that value being a
    server stating outright that its continuation lines are already spelled
    against the buffer — adjusting those would indent them twice. `2` and the
    absent case (what every pinned server sends) both go through the rule. The
    client advertises no `insertTextMode` default and does not read a
    `CompletionList.itemDefaults` one: nothing shipped sends it, and a default
    invented here would be a guess about text written to the file.
    **One line-start table per list.** Every item sourcekit-lsp sends carries a
    `textEdit`, so mapping a list with the one-shot `LSPPositionMap.range(for:in:)`
    would re-scan the whole buffer once per item — thirty full scans of a large file
    on every debounced keystroke. `publish` builds the table once and hands it to
    `edits(…)`; `resolveEdits(for:)` builds its own, being a single mapping on a
    path the user has already committed to. No name heuristic, no
    current-file bonus, no fuzzy quality: those exist in the tree-sitter provider
    because a bucket of names has no ranking of its own, while a server has spent
    real work on this order.
    **A reader, never a writer** (D10).
    Not an actor and not `@MainActor`: both request methods are `nonisolated async`
    so (SE-0338) their bodies run on the cooperative pool — ranking, position
    mapping and target-file reads all stay off the main thread — and the only
    mutable state is the small resolve table, guarded by an `NSLock` taken and
    released without crossing a suspension point.
    `definitions(for:)` applies **D2's guard** first: a request whose `text` is
    empty while its `offset` is non-zero was built by a call site that forgot to
    pass the buffer, and clamping its position to `0:0` would ask a confidently
    wrong question and get a confidently wrong *answer* — which never falls back,
    because it **is** an answer. So nothing is sent at all. **The same rule is
    applied to the response, through `LSPWorkspace.stillHolds(_:)`**: `prepare`
    guarantees the server's text *and* the open folder when it returns, not for the
    life of the question, so a second request that talked the server into different
    text — or a folder switch — while this one was outstanding leaves an answer about
    a document the caller's buffer no longer describes, or one from a project the user
    has left. Both request methods check before reading a response and drop it if
    either moved — a definition would otherwise be a plausible, wrong jump, and a
    completion's items carry *edits* in buffer coordinates that would then be
    applied to the file. That check is the last one this layer *can* make: the
    candidates it returns still cross a main-actor hop before a surface opens them,
    and closing that hop is the surface's own job, which both definition call sites
    do by pinning `SymbolIndexController.currentRootGeneration` before the hop (see
    `app-editor.md` and `app-ios.md`) — the same rule this file applies to the
    response, applied once more where the response is finally read. Candidates come back in
    the server's order, which is the answer's own order (sourcekit-lsp answers a
    type reference with the type *and* its memberwise initializer, and which the
    user meant is not something a sort key here could know better than the compiler
    did). Target texts are cached one per file rather than one per target, since a
    cross-module jump routinely answers with two locations in one 20 000-line
    generated interface. A target in the file being edited reads the **buffer**, not
    the disk, for the index's reason. **The relative path is computed from canonical
    components, not lexically**: `ProjectFileWalk.relativePath` strips a string
    prefix, which is right for paths the project walk produced — but a server answers
    with the path *it* resolved, and the recorded sourcekit-lsp really does report
    `/private/tmp/lspfix/pkg/…` for a project opened as `/tmp/lspfix/pkg`, which a
    lexical strip reads as "outside the root". So both the containment test and the
    displayed path go through `CanonicalPath`. A target whose file cannot be read is
    **dropped**, for the mirror-image reason candidates carry offsets at all:
    without its text there is no offset, and every consumer navigates by one.
    `maximumTargetFileBytes` (16 MiB) bounds that read — generous, because the files
    this actually reads are generated interfaces rather than user documents, and
    bounded anyway, because the alternative is loading whatever path a server named
    into memory on a ⌘-click. The candidate's `name` is the identifier the user
    clicked and its `kind` is `nil`: the server was asked "where", not "what".
    `completions(for:)` requires `request.offset` — **`nil` is unanswerable, never
    0**, D2's guard applied to the other request kind, since a prefix cannot be
    located in a buffer that may contain it a hundred times. A member request is
    sent as a `.` trigger rather than a plain invocation, because the two produce
    genuinely different lists from the same position and the editor has already
    decided which this is. The typed word's range comes from
    `IdentifierScanner.MemberContext.prefixRange` where one exists, so the two paths
    cannot disagree about what the user typed.
    **An item carries edits only when applying them literally matters.** An item
    that just replaces the typed word with its own text is exactly what AppKit's
    stock insertion already does, so `edits` stays empty there and the editor keeps
    its cheap path; edits appear when the item drags an `import` along (D4) or when
    the server chose a range other than the one the client typed — the two cases
    AppKit would get wrong.
    **A member `textEdit` that covers the typed dot is answered with the dot in
    the inserted text and without it in the display.** tsserver ranges a member
    item over the `.` the user just typed, so `inserted` is `".greet"` and a popup
    showing what it inserts reads every row under `greeter.` as `.greet`. So
    `publish` computes each item's `displayText` from that item's own **primary**
    edit against the buffer the request carried and the `typedWord` range it
    already holds, through `CompletionEdit.displayText(forTypedWordStartingAt:in:)`
    — which drops the head only because those characters already stand in the
    buffer, and therefore leaves `?.greet` on an optional receiver whole. Nothing
    downstream of that line moves: **the primary edit is unchanged**, and so are
    `edits(for:…)`, the ranking, the dedup key (still the *inserted* text), the
    cap and the resolve bookkeeping — what reaches the buffer is byte-identical.
    Every item without a primary edit, which is every edit-less item and the whole
    sourcekit-lsp member shape (zero-length ranges at the caret), passes `nil` and
    so displays exactly what it inserts.
    **"Completes to what is already typed" is asked of the displayed spelling
    too**, and that second guard is what the first one stops covering once a row
    may read differently from what it inserts. The two diverge by exactly the head
    the row drops, so a member the user already finished typing — `greeter.greet`,
    caret at the end — comes back from tsserver as `".greet"`, passes
    `inserted != typed`, and reads `greet`: the typed word itself. Such a row is
    not merely useless: `CompletionController` keys its snapshot by the displayed
    string and AppKit hands Esc back through that same table spelled as the typed
    word, so a row that answers to it turns a cancel into a *commit*, `import` line
    included. Dropping it here, on the one side that can see both spellings, keeps
    the controller's invariant ("no row is the typed word") true by construction.
    The dedup key stays the inserted text, as above — but it is *claimed* after
    that guard rather than before it, so a dropped row does not spend it: two
    items may carry one `newText` over different ranges, which makes them two
    different rows (the head a row drops is read off its own range), and the one
    that survives must not be mistaken for a duplicate of the one nobody sees.
    `hover(for:)` is `definitions(for:)` step for step — D2's empty-buffer guard,
    the language off the file name, `prepare` so the live buffer reaches the
    server before the question, `LSPPositionMap` on the way in and on the way out,
    `stillHolds(prepared)` before the answer is read — with two rules of its own
    (D25). **A server that does not advertise hover is not asked at all**, and the
    capability is read *after* `prepare` because `prepare` is what starts the
    server and therefore what produces the capability. **Every uncertainty is
    `nil`, including a server that answered**: content that normalizes to nothing
    is not a smaller answer but no answer, and a pointer resting on a keyword the
    server has nothing to say about must leave the screen exactly as it was. The
    staleness gate carries one extra consequence here — a popover is drawn *beside
    a range in the buffer*, so an answer about a document the server was talked out
    of underneath this one would be anchored to text that has since moved.
    `anchorRange(for:in:at:)` is what the caller measures "the pointer is still
    over the same thing" by: the server's own `range` when it sent one (usually
    wider than the identifier — a qualified name, an operator expression — and the
    honest span of the answer), otherwise the identifier under the offset, which is
    the same span the editor resolved before it decided to ask, and as a last
    resort an empty range at the offset. That last case reads as "already left", so
    the popover is re-asked rather than kept — the harmless direction to be wrong
    in.
    **A server's range is taken only when it covers the offset that was asked
    about** — the same untrusted-numbers stance `LSPPositionMap` takes on the way
    in, and not a formality: this one range is *both* where the popover is drawn
    and the editor's re-ask suppressor, so a range that does not contain the
    hovered offset (a degenerate `{0, 0}` being the realistic shape) would anchor
    the popover at the top of the file *and* fail the "still about the word under
    the pointer" test on every subsequent mouse-moved event — pointer jitter over
    one identifier becoming a dismiss-and-re-ask loop, on the one request path that
    runs whenever the pointer stops moving. An empty server range fails the same
    test and falls back to the identifier, which is strictly the better anchor.
    `resolveEdits(for:)` is the seam's defaulted extension point, implemented here
    and a no-op everywhere else. A handle names an item from the list the popup is
    *actually showing*: handles are monotonic and never reused, and the table is
    replaced wholesale when a new list is published, so a handle from a superseded
    list resolves to nothing rather than to whatever now sits at that number. The
    session is captured with the item, because a resolve is only meaningful to the
    process that produced the list.
    **The resolve contributes its `additionalTextEdits` and nothing else.** The
    *primary* edit is rebuilt from the item the popup published and the user
    committed, never from the answer. The spec does not let a resolve change what an
    item inserts and sourcekit-lsp echoes the whole item back, so this guards the
    *next* server rather than this one: an answer that came back leaner than it was
    sent — label, detail, the edits it kept back — would have `insertedText` fall
    through to `label`, and this is the one path in the layer whose result is written
    into the file rather than dropped. The popup would say `Greeter` and the buffer
    would get `Greeter(name:)`. Pinned by `LSPIntelligenceProviderTests`
    `.testAResolveThatDropsTheItemsOwnTextDoesNotChangeWhatIsInserted`.
    **The table is ordered by request, not by arrival.** Every `completions(for:)`
    claims a monotonic list token synchronously, before its first hop, and a publish
    whose token is older than the one already published keeps its items but does not
    touch the table — the generation-token discipline, applied to the one piece of
    state a completion leaves behind. Two completion requests overlap as a matter of
    course (the router abandons one at its deadline and it keeps running; the next
    keystroke asks again), and without the order the table belongs to whichever
    *finished* last: an older answer landing late would wipe the displayed list's
    handles and take D4's auto-import with them, silently, because a missing handle
    reads exactly like a superseded one.
    `LSPCompletionItemKind.symbolKind` maps to the editor's closed `SymbolKind` and
    answers `nil` where there is no honest equivalent (`.module`, `.snippet`,
    `.color`): `SymbolKind` is pinned by set equality against the shipped
    `symbols.scm` queries and cannot grow a case, and the kind is a presentation
    hint D6 ranks on anyway.
    The `LSPIntelligenceSource` conformance lives here because the answer is the
    workspace's and **the workspace is private to this provider** — nothing above the
    seam can reach past it to start, stop or interrogate a server.
    **`references(for:)` is `definitions(for:)` step for step**, plus hover's
    capability gate in front of it: D2's empty-buffer guard, the language off the
    file name, `prepare` so the live buffer reaches the server *before* the
    question, `LSPPositionMap` in and out, and `stillHolds` before the answer is
    read — a range computed against a document some other request talked the server
    out of underneath this one points at text that has moved. Every location becomes
    a `UsageResult` whose **display line is the editor's, not the server's** (D1),
    whose relative path is built from canonical components (a server answering
    `/private/tmp/…` about a project opened as `/tmp/…` is not outside the root),
    and whose `isTextual` is `false` — a server resolved the symbol, so the row
    means what it says. An **empty answer is returned as an empty answer** and
    converted into nothing (D36): what replaces it is `FindUsagesModel`'s decision,
    because a provider that walked the project to fill the gap would put a
    project-wide file scan inside the router's budget race, where the loser is
    abandoned mid-walk and nobody is left to say so.
    `FileTextCache` is the one thing this path adds that the definition path does
    not need: a jump answers with one or two locations, while a usages answer
    routinely holds hundreds in one file and every row needs both a mapped range and
    a display line — so the *line starts* are cached beside the text, keyed
    canonically, and seeded with the requesting file's **buffer** rather than its
    disk copy. Without it, `LineStartIndex.offsets(in:)` would run once per usage in
    a file, which on the identifier that motivates the 2 000 cap is the difference
    between a list and a hang.
    **Every *other* open tab's buffer beats its disk copy too**, and this is the one
    request in the layer where that matters. D2 says the live buffer travels with
    the question, and for every other request the question is about a single
    document, so `text` is the whole of it. A references answer is not: it names
    ranges in *other* files, and the diagnostics push channel (D29/D30) has already
    given the server every open served buffer — so a server asked about a project
    with a dirty background tab answers in that tab's **buffer** coordinates.
    Mapping those against the disk copy is not staleness but the wrong coordinate
    space, and it is the one way this path can produce a row that is *wrong* rather
    than absent: a plausible line, a preview drawn from unrelated text, and a reveal
    that `revealRange(naming:in:)` then correctly refuses. So `UsagesRequest` carries
    `openTexts` — keyed by URL, filled in by `FindUsagesModel` — and the cache
    consults them, canonically keyed like everything else here, before it reads a
    byte.
    **What fills it is `LSPWorkspace.lastSentTexts()`, not the live buffers**, and
    the distinction is the same one the rename path draws one file over: the push
    channel is *debounced*, so a background tab typed in less than 400 ms ago is a
    buffer no server has seen, and planning against it reintroduces the wrong
    coordinate space one step further out — with a `holds`-style check nowhere in
    sight, because a reading answer has none. A file that snapshot does not name is
    a file no server holds open, which means the server read it from **disk**, so
    the fallback there is `FileService` and never a buffer. The textual scan does
    prefer the live buffer for every file it reads, and that is right for *it*: it
    computes its own offsets, so the text it reads is its coordinate space by
    construction. The two provenances therefore consult different maps on purpose,
    and each consults the only one its offsets mean anything in — which is what
    keeps `UsageProvenance` from blurring rather than what would blur it.
    **The mapping loop is the one loop here that checks for cancellation**, because
    it is the one that can outlive its question and the one that is unbounded: a
    server naming a widely-used symbol legitimately answers tens of thousands of
    locations, each of which reads and indexes a file the cache then holds, while
    `RoutingIntelligenceProvider` has already abandoned the call at its budget and
    `FindUsagesModel` has started the project walk in its place. A loser that does
    not notice goes on reading the project beside the walk that replaced it. Every
    other mapped answer in this file is bounded by a popup's worth of items and
    needs no such stop. The row's **display path is cached on the same
    entry**, for the reason the canonical *root* is hoisted out of the loop above
    it: `CanonicalPath.canonical` is a symlink resolution on the file system and
    the answer is one constant per file, so deriving it per row would put a second
    round trip behind every one of up to two thousand rows — on top of the one the
    cache key already pays. The entry is what that key was computed from, so the
    two cannot disagree.
    **`renameEdits(for:)` is the same seven steps with two refusals of its own, and
    every outcome is `nil`** — there is nothing else it can answer (D35). A new name
    that is empty, or equal to the old one, is refused *before the wire*: the second
    would come back as a `WorkspaceEdit` full of edits replacing text with itself,
    which passes every verification in `RenameEditPlan` and rewrites a project's
    worth of files to no effect, taking each one's undo stack with it. The dialog
    refuses both too; this refuses them again because the dialog is not the only
    thing that can build a request. A server that answers with **no edits** answers
    `nil` here, because "no edits" and "I cannot rename this" are one fact to every
    caller and collapsing them is what keeps the writer bracket from being raised
    around a plan that touches nothing. `stillHolds` is load-bearing here in a way it
    is nowhere else in this file: every other answer that survives a stale document
    is a wrong *reading*, and this one would be a wrong *write*.
    **`canRename(_:)` is `canServe` and deliberately no more.** The stronger answer
    — does this server advertise `renameProvider` — is only knowable from a server
    that has finished its handshake, and starting one to decide whether to show a
    *sheet* is exactly what a free policy check must not do: on a cold project that
    is twenty seconds of a menu item deciding whether it is a menu item. So the
    capability is read where every other capability is (after `prepare`, inside
    `renameEdits(for:)`) and a server that turns out not to rename beeps after the
    request rather than before the dialog. It is named separately from `canServe`
    rather than spelled at the call site because the two are the same answer *today*
    and need not stay so.

  - `RoutingIntelligenceProvider.swift` — the one `CodeIntelligenceProviding` the
    editor surfaces hold, and the whole of phase 2a's user-visible contract.
    Everything below it can fail — there may be no Xcode, sourcekit-lsp may not
    understand the project, the process may be killed mid-session, the build system
    may take twenty seconds to resolve — and *none* of that is allowed to be
    visible. So the composition is deliberately dumb: ask the server, and if it does
    not answer something usable in time, ask the index. Both questions have the same
    shape and the same result type, so the caller cannot tell which one it got.
    `LSPIntelligenceSource` is defined here: `CodeIntelligenceProviding` plus the
    one question a server-backed provider can answer and an index-backed one cannot
    — *is it worth asking you at all*. The router needs that before it spends a
    budget, because "no server serves this language" and "the server timed out" must
    not cost the same: the first is every language but Swift, on every keystroke,
    and has to be free. It adds `Sendable`, which the deadline race requires because
    it puts the call in a child task.
    Three properties are load-bearing and each has a test. **Fallback is per
    request, and silent**: a timeout marks nothing, logs nothing and remembers
    nothing, and the next request asks the server again; the only state that
    outlives one question is D7's restart budget, which lives where the failures are
    counted. **A language with no server costs nothing**: `canServe` is asked first,
    so the output for Markdown, a Dockerfile, a scratch buffer or a machine with no
    toolchain is *the wrapped provider's output*, byte for byte —
    `RoutingIntelligenceProviderTests` pins that by equality on both request kinds
    rather than by inspection, because "phase 2a changed nothing for the other
    thirteen languages" is the promise most worth being unable to break by
    accident.
    **An empty answer is not an answer**: a server returning no definitions where
    the index has one has failed to answer the question, so an empty LSP result
    falls through, and only an empty result from *both* is empty — the case the
    editor beeps at, once.
    **Three questions are exempt from that rule, for two different reasons.**
    `hover` has no second source at all (D25). `renameEdits` has none either, and
    the argument is sharper because the command writes: the only thing tree-sitter
    could offer is a textual replace, which is indistinguishable from a correct
    rename right up to the moment two symbols share a spelling — at which point it
    has silently rewritten the one nobody was looking at, in files the user never
    opened. A command that is *unavailable* is a smaller harm than a command that
    is *usually right*. `references` is the third and the different one: it does
    have a second answer, but that answer is a walk of the project, which is a
    **model's** job and not a provider's (D36) — so what this layer owes there is a
    clean empty result, which `FindUsagesModel` reads as "ask the files". Both new
    methods are `canServe`-gated and budget-raced like every other — `references`
    on the `references` budget (definition's three seconds) and `renameEdits` on a
    `rename` budget of its own (twenty). The split is the point: every other span
    in these two tables bounds a race whose loser has something behind it, and this
    is the one that does not, so timing out a rename that would have succeeded is
    the single failure the layer cannot make invisible.
    `foldRegions(for:)` (D38) is not a fourth exemption — it is the ordinary shape
    read back: `canServe`-gated, raced on a `foldRegions` budget of its own, and an
    **empty server answer falls through to the scanner**, which is exactly what
    "an empty answer is not an answer" already says. That is also what keeps the
    two sources from ever mixing: the router returns one list or the other, never
    a union of them.
    `canRename(_:)` is **forwarded** rather than left reachable on the wrapped
    source, because the app holds *this* object: the seam's whole point is that
    nothing above it names the LSP layer, and a command reaching past the router for
    one question would be the first thing that did.
    **Two budgets over two different spans, both D7's numbers.** `LSPSession.Budgets`
    bounds the *server's* part of one exchange — it starts when the request is
    written. `RoutingIntelligenceProvider.Budgets` bounds the whole attempt:
    resolving the language, starting the process, waiting out the handshake,
    flushing the buffer, and only then asking. Nothing else can bound the first of
    those, and a first ⌘-click in a cold project would otherwise block for the 20 s
    sourcekit-lsp is allowed to resolve a build system in. So the cold-start
    behaviour is stated rather than accidental: **the first jump answers from
    tree-sitter while the server finishes starting behind it, and the next one is
    semantic** — the launch is an unstructured task `LSPWorkspace` owns, so
    abandoning the attempt does not abandon the launch.
    **D2's guard is not repeated here**, deliberately: a `DefinitionRequest` with no
    text is unanswerable *by a language server* specifically — the index looks names
    up and does not care — so the rule stays in `LSPIntelligenceProvider` and the
    router needs no special case, because "no answer" already routes to tree-sitter.
    The routed outcome is pinned by its own test all the same.
    `withBudget` races the call against a sleep and cancels the loser, which is what
    turns an abandoned definition into a `$/cancelRequest` on the wire rather than a
    server still computing an answer nobody will read. A cancelled sleep settles
    `nil` too, so a caller whose own task was cancelled falls through to the index
    instead of waiting out a budget for an answer it is about to discard.
    **It is deliberately not a task group**, which is what it was first written as
    and what it cannot be: a group awaits every child before returning, and
    `cancelAll()` only shortens a child that is *cancellable* — which the LSP
    attempt is not at the one point that matters. Joining a launch already in
    flight is `await Task.value` on a `Task<_, Never>`, and that ignores the
    awaiting task's cancellation entirely, so the group's implicit drain held the
    caller for the **handshake's** budget rather than the router's: the cold-start
    promise two paragraphs up came out exactly backwards, with the first ⌘-click in
    a cold project answering nothing for up to twenty seconds while the index had
    the answer the whole time. The two racers are therefore unstructured tasks
    meeting at a one-shot rendezvous (`FirstAnswer`, a lock around a single
    `CheckedContinuation` — a continuation must be resumed exactly once and here
    two tasks race to do it), and `withBudget` returns the moment either settles.
    The consequence worth stating: by the time the caller sees `nil` the loser's
    cancellation is *scheduled* rather than already written to the wire.
    `RoutingIntelligenceProviderTests` pins the whole thing against a scripted
    handshake that takes twenty times the budget, asserting by content — the answer
    arrives while `initialize` is still the only thing on the wire — rather than by
    stopwatch alone, and then that the abandoned launch still finished and made the
    *next* jump semantic.
    `resolveEdits` takes no `canServe` gate: the item in hand *came from* a live
    list, so the language question was settled when it was published, and an item
    from the other provider resolves to `[]` there anyway.
    **`hover(for:)` is the one method here that does not fall through** (D25), and
    the omission is the decision rather than an oversight — which is why it is
    stated on the method, on the type and here, since every other method in the
    file does fall through and a reader is entitled to assume this one does too.
    Tree-sitter knows names and locations, not types, and a plausible wrong answer
    is worse than none: a popover saying `count` is "a property declared on line
    40" when the pointer is over a completely different `count` is
    indistinguishable from a correct one, and unlike a wrong ⌘-click it is not even
    something the user asked for. So the shape is `canServe` first (a language with
    no server costs a function call, as everywhere else), then the same
    whole-attempt `withBudget` race the other two run — 1.5 s, beside them — and
    `nil` for every other outcome: no server, no capability, a timeout, an answer
    that normalized to nothing. Silently, like every fallback in this file.

### gopls (D17–D20)

Two Core files and one macOS-gated app file, which together are the *second*
registry contributor beside phase 2b's. They are documented here rather than in
`core-provisioning.md` because nothing about them is about bytes: there is no
manifest entry, no pinned digest, nothing downloaded and nothing unpacked. What
they share with 2b is stated in that document's own cross-reference.

  - `LSPGoToolchain.swift` — the value types, and nothing that acts. `LSPGopls`
    is the pin *as data*: component id (`"gopls"`, the one string the consent
    dictionary, the install root's directory and `LSPInstallEngine.remove(_:)`
    all key off), module path, version, the `v`-prefixed spelling `go install`
    wants (derived from the same constant rather than written twice), and the
    origin/SPDX pair the Settings row's sentence is built from.
    `executableSubpath` is a **constant** (`bin/gopls`) rather than whatever the
    build reported back, and that is load-bearing: D12 says the disk is the
    state, so where the binary sits inside its version directory has to be
    derivable from a directory listing after a relaunch, not a fact only the
    installing run remembered. The build's answer is therefore *checked* against
    it rather than trusted.
    `LSPGoToolchainReport` is what crosses the discovery seam — `.missing`, or
    `.found(goPath:searchPath:goplsPath:)`. **A gopls path without a `go` path is
    unrepresentable on purpose**: gopls with no toolchain behind it would start
    and answer nothing, and "no Go toolchain" is the one sentence the row can say
    truthfully there.
    `searchPath` is the second half of "a toolchain was found", and leaving it out
    is what made the first cut of this feature do nothing at all. **gopls does not
    take a `go` path**: it resolves the toolchain itself with `exec.LookPath("go")`
    and shells out to `go list`/`go env` for every package it loads, so a gopls
    started without `go` on its `PATH` starts cleanly and then answers nothing —
    which `RoutingIntelligenceProvider` cannot tell from "this file declares
    nothing", so it falls back silently while the Settings row says the server is
    installed. A Finder-launched app inherits `launchd`'s `PATH`
    (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains neither `/usr/local/go/bin`
    nor Homebrew's prefixes nor any version-manager shim directory, so that is the
    *normal* launch and not an edge case. The app therefore reports the `PATH` its
    search found the `go` under, and Core hands it to the server as
    `LSPServerDescription.environment` (`makeDescriptions()`) without ever learning
    what is in it — D9's rule intact: the app knows the paths, Core knows the rule.
    An **empty** search path is treated as no search path and contributes nothing,
    which the app cannot currently report; it is checked because the alternative
    failure is the quiet one — `PATH=""` registers a server that resolves nothing
    by name at all, strictly worse than the inherited environment the overlay
    exists to improve on, and identical in every surface the user can see.
    `LSPGoplsInstallation` keeps `.discovered(path:)` and
    `.appInstalled(version:path:)` apart as two cases rather than one "installed"
    with a flag, because Remove may only ever touch the second — a rule in the
    type instead of a check every view has to remember. `LSPGoConsentPrompt` is
    `LSPConsentPrompt`'s shape minus the byte count (nothing is downloaded) plus
    the `go` path, so the banner can name *whose* toolchain is about to do the
    work. `LSPGoServerRow` carries D19's states and makes every button's
    availability a property (`canInstall`, `canRemove`), so both surfaces stay
    thin. `canRemove` is keyed on a `hasFilesOnDisk` flag rather than on the
    status being `.appInstalled`, `LSPServerRow`'s field for `LSPServerRow`'s
    reason: a version directory a *pin bump* moved past reads as `.notInstalled`
    (or `.discovered`, on a machine that also has the user's own copy) while
    still being this app's to reclaim, and the only other thing that ever deletes
    one is `removeOtherVersions()` — which runs inside a **successful** install of
    the new pin. Without the flag, a user whose machine cannot build the new
    version (offline, proxy blocked, toolchain too old) or who declines afterwards
    keeps tens of megabytes with no button in the app that admits they are there.
    Its `Status` has a **sixth** case beside D19's five, `pending`, for
    `LSPToolchain.Resolution.pending`'s reason — discovery shells out to `go`, so
    it cannot answer inside the turn that draws the row, and a row that guessed
    "no Go toolchain" for that first moment would say something false and then
    quietly correct itself.

  - `LSPGoplsProvisioning.swift` — the two seams, the typed error and the
    `@MainActor` model that owns everything decision-shaped.
    `LSPGoToolchainDiscovering` answers a *report*, not a search (D18);
    `LSPGoModuleInstalling` is deliberately generic — module, version, the `go`
    to build with, the bin directory to build into — rather than a
    `func installGopls()`, so the seam describes what `go install` *is* and the
    pin stays data in `LSPGopls`. `LSPGoInstallError` has no `checksumMismatch`
    case, and that absence is D17: nothing is downloaded here, so there is
    nothing to hash.
    `LSPGoplsProvisioningModel` is `LSPProvisioningModel`'s shape over different
    facts. Lifecycle: `pending` until `discover()` answers (called once at launch
    from `PisakaApp.init`, and joined rather than repeated by any later caller,
    so the answer — **including the negative one** — is a per-app-run fact on
    Core's side too, not only inside whatever cache the seam keeps).
    `installation` implements D19's preference directly: the app's own copy is
    read off the install root and **wins**, the discovered one is the fallback.
    `consentPrompt(forOpening:)` is the banner's whole rule and is read off the
    published `row` rather than re-derived from the disk, for
    `LSPProvisioningModel.consentPrompt(forOpening:)`'s reason — the banner asks
    it from its `body`.
    Three rules are worth reading as decisions. **`install()` with no toolchain
    does nothing at all** — not a recorded failure, not a recorded consent:
    there is nothing to build with, and a row reading "no Go toolchain" beside a
    sentence about a build that did not happen would describe an attempt nobody
    made. **`prepareForOpening` does not retry a failed attempt this app run**,
    which is the whole difference between "installs on first use" and a retry
    loop — a failed build leaves nothing installed, so without the guard every
    switch back to a `.go` tab would start another `go install`, and since
    `install()` clears `failureMessage` before each attempt, the one place D15
    reports the failure would be wiped by the very tab switch that re-triggered
    it. The budget is "once per app run, automatically"; the Settings row's Retry
    stays unconditional, and so does the next launch. It does, however,
    **`await discover()` rather than read the report** — the one thing that turns
    that budget into a real first-use install. Discovery is kicked off unawaited at
    launch and costs a subprocess (up to a login shell), while the caller is the
    banner's `.task`, which fires within milliseconds of the first render: a
    restored `.go` tab regularly arrives while the report is still `nil`, and
    reading it there returned silently *for the whole app run*, since that trigger
    does not fire again until the language or the project root changes and nothing
    else calls this. `discover()` coalesces onto the one task, so the wait is paid
    once and the non-Go guard keeps it out of the ordinary tab open. And
    **`remove()` falls back
    to a user-installed gopls** where one exists: it records `declined`, which
    describes what happened operationally (the next `.go` file must not silently
    rebuild what was just removed), but that consent gates *building* and nothing
    else — this app neither put the other binary there nor was asked about it.
    The install is D13 reused rather than reimplemented: stage under the layout's
    staging directory, point `GOBIN` at it, check the executable landed where
    `executableSubpath` says, one `move`, then drop older versions best-effort.
    Every failure before the `move` discards the staging tree and rethrows, so
    "whatever was installed before is exactly as it was" needs no rollback to be
    true. The staging path is discarded before it is created, because
    `stagingCounter` restarts at zero every launch and `ensureDirectory` succeeds
    on a directory that already exists — which would adopt a half-written tree
    from a previous run rather than refuse it. Removal is D16's push-then-delete,
    with re-entrant calls and calls during an install returning immediately.
    `makeDescriptions()` requires a toolchain **even for a discovered gopls**,
    since gopls shells out to `go list` and without one would start, answer
    nothing, and spend D7's restart budget per request; the entry itself is a
    plain `.executable(path:)` with no arguments (gopls speaks LSP over stdio by
    default), so Core learns no paths and gains no launch kind. It requires the
    report's `searchPath` for the same reason one step further on — "a toolchain
    exists" is not "gopls can find it", and the guard is what stops the app
    registering a server that starts and answers nothing on every machine whose
    `go` is outside launchd's four directories, which is all of them. The path
    travels as the description's `environment` (`["PATH": …]`), the one field that
    is not a constant here.
    A **reader**, like the rest of this layer: it walks its own install root and
    touches nothing of the user's, so it takes no writer gate and is not gated by
    one.

  - `Sources/Pisaka/LSPGoToolchainService.swift` (macOS) — the app's whole
    contribution: both seams in one file, because they are not two technologies
    (unlike 2b's `URLSession`/`tar` pair, both of these are "run the user's `go`
    and read what it says"). Full entry in `app-editor.md`, beside
    `LSPToolchain.swift` whose discipline it follows.

### rust-analyzer (D21–D24)

Two Core files and one macOS-gated app file — the *third* registry contributor.
They are documented here rather than in `core-provisioning.md` for the same reason
gopls's are, but only half applies: the bytes **do** live over there (the pinned
`LSPComponent`, the `.gzip` format, the executable gate and the pin procedure are
all 2b's machinery, reused as-is), while what is here is everything that is a
*rule* — when a server may be offered, which copy wins, what the row may do, and
what the registry gets.

  - `LSPRustToolchain.swift` — the value types, and nothing that acts.
    `LSPRustAnalyzer` is the pin as data, and it is deliberately **thinner than
    `LSPGopls`**: it carries only what a manifest record has no field for — the
    component id (`"rust-analyzer"`, the one string the consent dictionary, the
    install root's directory and `LSPInstallEngine.remove(_:)` all key off), the
    display name, and the origin URL the Settings row's licence sentence names —
    plus `component(in:)`. The version, the SPDX expression and the executable's
    position inside the version directory are read *through* that from whichever
    manifest the engine was built over, because unlike gopls this server **is** a
    pinned component, so restating any of them here would be a second spelling of
    a pin the by-hand update procedure moves. It is also what lets the tests drive
    the model with a fixture pin and prove it reads the data rather than a
    constant. `component(in:)` answering `nil` is a real answer rather than a
    precondition: this layer's uniform response to data it cannot act on is
    *absence* — nothing offered, nothing installed, Rust answered by the index.
    `LSPRustToolchainReport` is what crosses the discovery seam — `.missing`, or
    `.found(cargoPath:searchPath:rustAnalyzerPath:)`. **A rust-analyzer path
    without a `cargo` path is unrepresentable on purpose**, which is D23 stated in
    the type: rust-analyzer shells out to `cargo` to build the project model, so
    without a toolchain it starts, answers almost nothing, and burns D7's restart
    budget per request while every surface claims it is installed — and
    `RoutingIntelligenceProvider` cannot see that, since an empty answer and a
    file that declares nothing are the same value at that seam. `searchPath` is
    the second half of "a toolchain was found", `LSPGoToolchainReport`'s field for
    its reason one server along: a Finder-launched app inherits `launchd`'s
    `/usr/bin:/bin:/usr/sbin:/sbin`, which contains neither `~/.cargo/bin` nor
    Homebrew's prefixes nor any version-manager shim, so a rust-analyzer started
    under it would resolve no `cargo` at all. That is the *normal* launch, not an
    edge case. `LSPRustAnalyzerInstallation` keeps `.discovered(path:)` and
    `.appInstalled(version:path:)` apart as two cases rather than one "installed"
    with a flag, because Remove may only ever touch the second — a rule in the
    type instead of a check every view has to remember.
    `LSPRustConsentPrompt` is `LSPGoConsentPrompt`'s shape **plus a byte count**,
    which is the field that makes Rust the hybrid: accepting gopls runs the user's
    own toolchain and downloads nothing this app can size, while accepting this
    fetches a pinned artifact whose size the manifest knows exactly, and D15's
    rule is that nobody is asked to download something unsized. The count is
    `pendingDownloadByteCount` — what is still missing rather than the gross
    total, the same number the row shows, and zero once it is on disk.
    `LSPRustServerRow` carries D24's seven states and makes every button's
    availability a property (`canInstall`, `canRemove`), so both surfaces stay
    thin; it also carries `licenseSPDX` and `pendingDownloadByteCount` for that
    same reason, since the view holds no logic and the row is where both reach the
    manifest. `canInstall` deliberately refuses over a *discovered* copy: it
    already answers, so a 13 MB download would buy a second copy of the same
    program plus a Remove button, and D24's preference rule would then silently
    switch which binary is running. It also requires a non-empty `version`, which
    is how "the manifest describes no such component" reaches the button: that
    state reads as `.notInstalled` — the honest status, since nothing is — and
    `consentPrompt` and `install()` both guard on the component, so without this
    clause the row would be the one surface offering an action that silently does
    nothing. `canRemove` is keyed on `hasFilesOnDisk`
    rather than on the status being `.appInstalled`, `LSPGoServerRow`'s field for
    its reason — a version directory a pin bump stranded reads as `.notInstalled`
    (or `.discovered`) while still being this app's to reclaim, and the only other
    thing that deletes one runs inside a *successful* install of the new pin.
    `Status.pending` is there for `LSPToolchain.Resolution.pending`'s reason:
    discovery may shell out to a login shell, so it cannot answer inside the turn
    that draws the row, and a row guessing "no Rust toolchain" for that first
    moment would say something false and then quietly correct itself.

  - `LSPRustProvisioning.swift` — the one seam and the `@MainActor` model.
    `LSPRustToolchainDiscovering` answers a *report*, not a search (D23). **There
    is deliberately no second seam**, and that is the whole difference from gopls:
    the install is `LSPInstallEngine.install(_:)` over the pinned component and
    the download/unpack pair 2b already has (D21), so this protocol is the entire
    Core-side addition.
    `LSPRustProvisioningModel` is `LSPGoplsProvisioningModel`'s shape over 2b's
    engine. It takes **no `FileServicing` at all**, unlike the gopls model: every
    disk question — is it installed, where is the executable, are there files to
    reclaim, how many bytes are still to fetch — is already an engine method,
    because this server *is* a manifest component. Lifecycle: `pending` until
    `discover()` answers, called once at launch from `PisakaApp.init` and joined
    rather than repeated by any later caller, so the answer — **including the
    negative one** — is a per-app-run fact on Core's side too and not only inside
    whatever cache the seam keeps. The row and the descriptions are updated
    *inside* that task rather than after awaiting it, so a second caller joining
    mid-flight returns to finished state. `installation` implements D24 directly:
    the app's own copy is read off the install root and **wins**, the discovered
    one is the fallback. `status()` reads *this model's* attempt before the
    engine's, so the row says "installing…" from the moment the user says yes
    rather than from the moment the engine claims the component.
    Four rules read as decisions. **`install()` with no toolchain does nothing at
    all** — not a download, not a recorded failure, not a recorded consent (D23) —
    for the gopls rule's reason: a row reading "no Rust toolchain" beside a
    sentence about a download nobody made would be describing an attempt nobody
    made. **`prepareForOpening` does not retry a failed *install* this app run**,
    which is the whole difference between "installs on first use" and a retry
    loop — but a failed **removal** suppresses nothing, and the guard reads
    `failure?.wasRemoval != false` rather than `failure == nil` for exactly that
    reason: a removal that threw leaves consent `accepted` (only a *successful*
    removal declines), and the state it can leave behind — the pinned version gone
    while some other version directory refused to go — is one an install fixes
    rather than one it repeats. The button beside the sentence already draws that
    distinction (`failureWasRemoval`); the guard draws the same one.
    It does `await discover()` rather than read the report, because
    discovery is kicked off unawaited at launch while this runs from the banner's
    `.task`, so a restored `.rs` tab regularly arrives before the answer and
    reading a still-`nil` report there would decline silently *for the whole app
    run*. **Installing records `accepted` first**, since the Settings row is the
    one place a declined server is turned around and it would be strange to
    install it and then let the next launch decline to keep it; the attempt is
    coalesced with the claim made synchronously between check and store, so two
    accepts produce one download. **`remove()` is push-then-delete** (D16),
    records `declined` — the only answer that describes what happened
    operationally — refuses when there is nothing under the install root, and
    returns immediately when re-entered or called during an install.
    `makeDescriptions()` contributes a plain `.executable(path:)` with no
    arguments (rust-analyzer speaks LSP over stdio by default), requires a
    toolchain **even for a discovered copy**, and requires a non-empty
    `searchPath` — `PATH=""` would register a server that resolves nothing by
    name at all, strictly worse than the inherited environment the overlay exists
    to improve on and identical in every surface a user can see. `publish()` fires
    only on an actual change and `onDescriptionsChange` is awaited, because the
    push is what shuts the running server down before `remove()` deletes the
    executable it was running from.
    A **reader**, like the rest of this layer: it walks its own install root and
    touches nothing of the user's, so it takes no writer gate and is not gated by
    one.

  - `Sources/Pisaka/LSPRustToolchainService.swift` (macOS) — one seam and no
    second one: where `cargo` and any existing `rust-analyzer` are on **this** Mac
    (D23). Full entry in `app-editor.md`, beside `LSPGoToolchainService.swift`
    whose search order and discipline it follows.

### Diagnostics (D29–D34)

Four Core files — three pure value/engine types and one observable model — that
turn `publishDiagnostics` pushes into state three macOS surfaces can share. They
sit *beside* the request stack rather than under it: nothing above reads them to
answer a question the editor asked, and the only thing they consume is the
workspace's sink. The app-side half of the feature is documented where it lives:
`LSPDocumentSyncController.swift` and the coordinator wiring in `app-editor.md`,
the overlay cache, the ruler's marker column and `SyntaxTheme`'s colors in
`app-editor-overlays.md`, and `ProblemsPanelView.swift` in `app-window.md`.

  - `Diagnostic.swift` — the buffer-anchored value type, its severity vocabulary,
    the wire→buffer mapping, the panel's ordering key, and hover's merged content.
    Everything downstream of the mapping works in UTF-16 offsets and never sees an
    LSP position again; `line` counts lines by `LSPPositionMap.lineStarts(in:)`'s
    separators, so it can differ from the gutter's numbering only by D1's bounded
    NEL/LS/PS divergence, which no surface ever prints raw.
    `DiagnosticSeverity` is the **closed** set the three surfaces switch over
    (`error`/`warning`/`information`/`hint`) beside the wire's open
    `LSPDiagnosticSeverity`, and the conversion between them carries the feature's
    one client-side judgement call: **an absent or unknown wire severity becomes
    `.error`**, which is what the spec's "the client decides" has to mean for an
    editor that must not hide a failure — an unrecognised number is more plausibly
    a server naming something serious than something trivial, so the benefit of the
    doubt goes to red. `Comparable` orders by seriousness with `.error` greatest
    (deliberately the reverse of the wire integers, hence a written-out `<`),
    because both per-line folding and the ordering key ask "which of these wins"
    and `max` should be the answer.
    `make(from:in:lineStarts:url:)` maps one wire diagnostic through
    `LSPPositionMap.range(for:in:lineStarts:)` against the text the server was told
    (D31), taking the caller's precomputed line starts so a push of N entries scans
    the buffer once. Out-of-range positions clamp rather than reject — a push
    computed against slightly stale text still points somewhere honest — and the
    one placement that cannot be clamped returns `nil`: unreachable through
    today's clamping rules, kept as a gate so a future change to them cannot hand
    TextKit an `NSRange` it traps on.
    `OrderingKey` (path, then start offset, then most severe first at one
    start — severity outranks every remaining field, so the worst complaint at a
    position is always read first — then shorter span, then message and source
    lexicographically among equals, absent source before any present one) is a **total**
    order decided here rather than in the view, because two surfaces — the
    Problems list and hover's merged messages — must agree on reading order
    without consulting each other, and a stable sort needs a key with no ties
    unless the diagnostics are equal. The tie-break fields are what make that
    claim true rather than aspirational: real servers do emit two complaints at
    one position with one severity, and Swift's sort is not guaranteed stable,
    so without them the reading order would depend on the push's arrival order.
    `sortedByOrderingKey(_:)` is how every one of those sorts is spelled, and the
    reason is measured rather than stylistic: `orderingKey` is computed, and
    building one standardizes a `URL` and allocates its path, so the naive
    `sorted { $0.orderingKey < $1.orderingKey }` pays that twice per *comparison*.
    Both call sites sit on a per-keystroke path — the panel's rows and counts
    re-evaluate on every `@Published` store mutation — and n is the findings in one
    file, which one unresolved import makes three digits. Decorate-sort-undecorate
    builds each key once.
    `DiagnosticRun` + `merged(_:)` is the editor overlay's value and its whole
    algorithm, in Core for the ordinary reason (pure, therefore unit-tested):
    freely-overlapping runs become the ascending non-overlapping form, each span
    carrying the worst severity covering it, adjacent equal severities coalesced. A
    **zero-length run widens to one unit** rather than being dropped — servers emit
    empty ranges, and the gutter, hover and the panel all show them, so silently
    skipping only the squiggle would flag a line with nothing under it; one at the
    very end of the buffer widens past it and the paint side clamps it away, which
    is the same "nothing to draw" a drop produced without also losing the drawable
    ones.
    `hoverContent(for:merging:)` is D34's builder: each message as a
    severity-labelled prose segment ("error: …" — the label is what keeps a bare
    message from reading as documentation), in `orderingKey` order, above the type
    answer's segments when there is one and alone when there is not. It goes
    through `HoverContent`'s checking initializer, so D26's length caps run exactly
    once; cutting to a drawn line count stays the renderer's call, as for any other
    answer. An empty set falls through to the type answer unchanged — segments and
    truncation mark alike — and an empty set with no type answer is `nil`: there is
    no empty popover (D25).
    Foundation-only, like everything here.

  - `DiagnosticShift.swift` — the pure incremental rule that keeps a stored set
    pointing at its code across edits (D32), in ``BlameShift.updated``'s exact
    shape: arithmetic over the pre-edit and post-edit line-start arrays the caller
    already holds at `NSTextStorage.didProcessEditing` time, with no text and no
    re-scan. The rule is deliberately three-way: a diagnostic entirely before the
    edited span is untouched, one entirely after is shifted by `changeInLength`
    and renumbered from `newLineStarts`, and one intersecting the touched span is
    **dropped** — so the error being fixed loses its underline on the first
    keystroke while errors elsewhere stay anchored, rather than drifting (no
    shift) or blinking off wholesale (a blanket clear). Both edge comparisons are
    half-open and load-bearing at both edges: a diagnostic ending exactly at the
    insertion point survives (dropping it would blink on ordinary typing at the
    caret), and so does one starting exactly at a deletion's start. A survivor's
    `line` is recomputed only when it actually moved — re-deriving an untouched
    one could launder a divergence between the two separator sets, not fix it.
    Inconsistent input returns `[]`, the honest "unknown": tables not anchored at
    zero, negative ranges, overflow anywhere in the span arithmetic (checked with
    the reporting overflows, since `Int.max`-sized garbage must fall to the
    fallback rather than trap), and one bad entry poisons the whole answer on
    purpose — callers re-sync on the next typing pause, and a partially-shifted
    array looks exactly like truth. What is deliberately *not* checked is spelled
    out too: an edit past the old buffer's end or a survivor past the new one
    cannot be seen from line-start tables alone, and yielding a shifted set there
    beats inventing a parameter for input `NSTextStorage` cannot produce. D32
    rejects replaying an edit queue onto a late push as exact but heavy; this is
    the cheap half of that bargain, correct for every edit *after* the accepted
    push and self-correcting for anything before it because the model refuses such
    pushes outright.

  - `DiagnosticStore.swift` — the value type keyed by document URL that both the
    model holds and the surfaces read, carrying provenance per entry (*which*
    `(serverID, root)` reported a document's set) because two
    clearing rules are keyed by that pair (D33). The push's wire version is
    deliberately *not* stored — the acceptance gate reads it off the model's own
    sync records, so an entry copy would be write-only state. The server key mirrors the workspace's `(server, root)` as its own
    public type rather than exposing workspace internals; URLs are standardized at
    the boundary, with the canonical probe left to `CanonicalPath` where display
    paths need it — same-file identity is decided once, not re-derived under every
    key. Mutations are wholesale or scoped: `replace(url:serverKey:
    diagnostics:)` is LSP semantics including the empty push (an "all clear" lands
    as an empty entry so provenance survives for the next comparison),
    `clear(url:)`, `clear(serverKey:)` (D33's teardown clears),
    `clearAll()` (the folder changed), and `apply(shift:to:)` installing a shifted
    set while keeping its provenance — refusing to mint an entry for a document
    nothing was ever pushed about, because fabricated provenance is precisely what
    the gate below would then trust.
    Queries, all pure: `diagnostics(at:in:)` for hover (half-open containment,
    with the one exception that a zero-length diagnostic contains exactly its own
    offset); `worstSeverityPerLine(url:lineCount:lineStarts:)` returning exactly
    `lineCount` entries — the ruler indexes the result by line, so the
    `BlameShift` invariant is applied here rather than hoped for downstream —
    marking every line a multi-line diagnostic spans, which is why it grew the
    `lineStarts:` parameter the plan did not name: line geometry is the one thing
    a store of offsets deliberately does not keep, and the caller already holds
    the table. **Both ends of the marked band come from that table**, never from
    the stored `Diagnostic.line` — that number counts by LSP's separator set
    (D1) and is only ever *printed* (the panel's `:N`), so reading it as geometry
    here would mix two numberings and, in a file delimited by NEL/LS/PS, paint a
    one-line diagnostic as a band as tall as every exotic separator above it.
    A diagnostic starting outside the requested window is skipped rather than
    clamped onto line 0, and inconsistent geometry degrades to all-`nil` at the
    requested count, never a crash indexing past the array; `rows(relativeTo:)` grouping by file in
    `orderingKey` order with relative path components via `CanonicalPath`/
    `DisplayPath`'s two-probe order (absolute components for a file outside the
    root — the panel invents no `~` story the breadcrumb would disagree with) and
    collapsing byte-identical rows, a *rendering* rule the view's content-keyed
    `ForEach` rides on: rows are keyed by their flattened fields (`Row`'s note),
    where duplicate ids are undefined behavior rather than a merge, while the
    entry itself keeps every diagnostic so hover, the overlay and `counts` still
    see both;
    and `counts`, errors and warnings only, because the header answers "how much
    is broken", not "how much was said".

  - `DiagnosticsModel.swift` — the `@MainActor ObservableObject`
    (`SymbolIndexModel`'s precedent) that owns a store plus the sync/revision
    bookkeeping deciding which pushes may land, republished wholesale on every
    mutation so the squiggle overlay, the gutter column and the panel observe one
    truth. **A reader** (D10): it never raises `autosave.suspend()`/
    `localChanges.beginRevert()` and is never gated by them — diagnostics only
    look at buffers, and a set landing mid-revert costs at worst one wrong
    squiggle the next 400 ms sync's push corrects.
    The acceptance gate is D32 stated as code: a `published` event is applied only
    when its version matches the version recorded at the document's last reported
    sync (`noteSynced(url:version:revision:)`; absent-on-push means unversioned,
    and then revision alone speaks) **and** the buffer revision pinned at that sync
    still equals the document's current revision — i.e. nothing was typed between
    the sync and the push. A push computed against moved-past text is dropped
    outright, never replayed against an edit log; the last keystroke has already
    scheduled one more sync whose push will have no edits after it, which is what
    makes dropping self-correcting. Edits after an *accepted* push go through
    `noteEdit(...)` → `DiagnosticShift.updated` (shift + revision bump — and it
    reads the entry before touching the store, so a document with *nothing to shift*
    costs no `objectWillChange` at all: `apply(shift:to:)` already no-ops there, but
    calling it is still a mutating access to a `@Published` value, which would wake
    the panel's rows and the editor's whole-document gutter pass once per keystroke.
    The skip covers both shapes of "nothing" — no entry at all (every plain-text
    file) and an **empty** entry, which is what an all-clear push installs and so
    the steady state of every file that currently compiles; shifting an empty set
    can only produce an empty set), a
    wholesale buffer replacement (a `reloadFromDisk`, Replace All or merge apply,
    on-screen or reported off-screen) through `noteBufferReplaced(url:)` (clear +
    bump + drop the sync record — the server no longer holds text anyone mapped a
    push against); a plain tab switch is deliberately *not* one of these, so a
    background document's set and sync record survive the view swap and its
    squiggles repaint from the store on switching back.
    **The hold-and-reconcile step** closes the one hole dropping leaves: the
    workspace commits a flushed version several main-actor hops before the
    controller's report lands, and a fast server's publish can be routed inside
    that window — where "rejected" would strand the document blank until the next
    interaction, on exactly the first-diagnosis moment the feature exists for
    (`attachNotificationConsumer`'s own comment concedes a real server pushes
    "well before the flush that carried it returns"). So a push that finds no
    record, or a record pinned to a revision the buffer has moved past — either
    signature of a report still in flight — is **held** (one per document, newest
    wins, the event alone with no revision beside it) and judged when the next record lands:
    admitted only if that sync itself is current and the versions match (absent
    passes), because the hold's survival plus the landing record together pin it
    to exactly that sync's text. Every invalidating event drops holds — `noteEdit`,
    `noteBufferReplaced`, both clears (scoped: a server clear takes only that
    server's), and the folder change — so a hold can never resurrect anything a
    teardown or a keystroke condemned — and is why no hold-time revision is stored
    at all: nothing that bumps a revision leaves a hold behind, so the hold's mere
    survival is already the proof a stored copy would have re-checked.
    A version mismatch against a *current* record is held too, not dropped:
    with no keystroke to point at, it is either a late replay — which the
    reconcile's version half then discards unreplayed — or the settling flush's
    own publish beating its report home, which it admits; dropping would strand
    the document blank until the next interaction, the exact failure the hold
    exists to prevent.
    One honest trade: a held unversioned push may rarely describe the previous
    flush's text; accepting it draws at worst one briefly-wrong set for the
    instant before the settling answer replaces it — D32's own trade, made once,
    here. `noteDocumentClosed(url:)` — the last tab on the file closed — takes the
    document's *whole* record with it: the set, the hold, the sync record and the
    revision. The two maps are then bounded by the open tabs rather than by every
    file the session ever opened, and a file reopened later is gated from zero
    instead of against the numbers of its previous life. It is reached **two ways
    and needs both**: `receive(.cleared(.document))`, which the workspace emits only
    for a URI it still *held* — every teardown wipes its document table first, so a
    crash-then-close emits nothing — and a direct call from the app's own "no tab
    shows this file any more" guard (`forgetIndexedBuffer`, beside the `didClose`),
    which is the one that fires for *every* close and so also bounds the revision
    map for files no server ever served (`noteEdit` mints a revision for any buffer
    that is typed in, served or not). Idempotent, so arriving both ways costs
    nothing. `prepareForFolderChange()`
    clears bookkeeping along with the
    store in the same main-actor turn as the workspace's own token, so no push
    from an old project's server can pass — and only fires when the root actually
    changed, since re-opening the open folder leaves every tab in place with
    nothing that would repopulate an emptied store. `currentRevision(for:)`
    exists for
    exactly one caller: the sync controller pinning it synchronously before its
    hop — the generation-token rule, one layer up from the models it usually
    guards. The read-only queries forward to the store unchanged; the views hold
    no logic to be thin about.

## Decisions

**D1 — Position mapping and line separators.** `LSPPositionMap` scans line starts
using **LSP's separator set only: LF, CRLF, CR** — not `LineStartIndex`'s wider
set — because the number we send must be the number the server counted. Positions
are UTF-16 code units within the line (`positionEncoding: utf-16`, advertised
explicitly rather than relied on as the default). Every LSP position received is
converted to an absolute UTF-16 offset first; anything user-visible (the picker's
line number) is then derived with `LineStartIndex`, so what the user reads still
matches the gutter.

**D2 — Document sync is request-driven, full-text.** `textDocument/didChange` uses
`TextDocumentSyncKind.full`. The buffer text is not pushed on every keystroke:
each request carries the live buffer, and `LSPWorkspace.prepare` sends `didOpen`
— or a `didChange` with a bumped version — **immediately before** the request
whenever the text differs from what that server was last told. This satisfies the
correctness rule ("the server has the current text before any request against it")
with zero editor wiring for change notification. `didClose` is sent when the last
tab on a file closes and for every open document on a folder switch.
The new `DefinitionRequest.text` and `CompletionRequest.offset` fields are
defaulted so no existing call site breaks at compile time, which makes a
*forgotten* call site the real hazard — it would hand the LSP layer an empty
string (or no caret) and get positions clamped to `0:0`, wrong answers that never
trigger fallback. Two things close that hole: both macOS editor call sites were
updated in the same task that added the fields, and **the LSP layer treats a
definition request whose `text` is empty while its `offset` is non-zero, and a
completion request with no `offset`, as unanswerable** — it does not clamp, it
sends nothing, and routing falls back. A genuinely empty buffer has offset 0 and
stays answerable.

**D3 — A definition target outside the project root opens in a separate,
read-only window**, modeled on `DiffWindowController` + `DiffView`'s read-only
pane. No tab, no `WorkspaceModel`, no autosave — so a jump into an SDK interface
or a dependency checkout **structurally** cannot write outside the root. Targets
inside the root keep the tab-open + `EditorRevealState` path unchanged. The flag
lives on the candidate (`DefinitionCandidate.isOutsideProjectRoot`, defaulted
`false`) because the project root is the provider's knowledge, not the view's.

**D4 — Auto-import.** An LSP completion item carries its own edits
(`CompletionItem.edits`, UTF-16 buffer ranges): the primary replacement plus any
`additionalTextEdits`. `EditorTextView.insertCompletion` applies an item that
carries edits **itself** — one undo group, edits last-to-first so earlier offsets
stay valid, caret after the inserted text and never at the import. An item with no
edits keeps going through `super` exactly as before. Items the server marks as
needing `completionItem/resolve` are resolved **concurrently in the background the
moment the list is shown**, because the user's pick is hundreds of milliseconds
later. *Known limit:* if an item is committed before its resolve lands, the
insertion happens first and the import edit is applied when it arrives, as a
second undo step — and only while the buffer is otherwise unchanged.

**D5 — No snippet support is advertised**, so `newText` should always be plain
text and nothing has to strip `${1:placeholder}` syntax. Advertising it is not the
same as being obeyed, though, so the guarantee is *checked* as well as asked for
— and checked against the text, not the label on it: `publish` drops an item whose
`insertTextFormat` is present and not `1` **and** whose inserted text contains a
`$` or a `\\`, the only two scalars the snippet grammar gives meaning to. A server
that mislabels literal text (`yaml-language-server` marks every property
completion `Snippet` unconditionally) still completes; a server that would write
placeholder syntax into the buffer still does not. *Known limit:* such an item's
row shows the text it inserts, so a YAML property reads `services:\n  ` in the
popup rather than `services` — `displayText` may differ from `text` only by
dropping a head that re-writes characters already in the buffer, and this head is
not one.

**D6 — Ranking for LSP-answered requests trusts the server**: items sorted by
`sortText ?? label`, preserving server array order on ties, then the existing
hygiene (drop the item that would expand as a snippet, drop the item identical to
the typed token, dedup by inserted text, cap
at `SymbolIntelligenceProvider.defaultCompletionLimit`). No name heuristics on
top. The recorded transcript is what pins this rather than a constructed example:
sourcekit-lsp put `Greeter` *last* in the array with the *lowest* `sortText`.
**One key sits above `sortText`, and it is not a ranking** (added with the YAML
server): the spec makes matching the client's job and `yaml-language-server`
leaves it entirely — it answers the caret's whole schema property set, the same 93
items for `ima` as for an empty prefix — so ranked on `label` and cut at the cap
the popup is an alphabetical slice of the schema with `image` below the cut.
`FuzzyMatch.matches(_:query:)` over `filterText ?? label` therefore partitions the
list into "answers what was typed" and "does not", and the cap reaches the first
half first. Deliberately **not a filter**: a server's matching may be looser than
this one's boundary rule (the recorded transcript answers `Gree` with
`VM_MEMORY_MALLOC_LARGE_REUSED`) and nothing it sent is discarded. Within each
half D6 is untouched, and an empty prefix is one half.

**D7 — Budgets.** Per request: completion 1.5 s, definition 3 s (the 150 ms
completion debounce has already elapsed, and a jump is a deliberate act worth
waiting a beat for). Handshake 20 s. Crash/EOF: restart with 1 s / 2 s / 4 s
backoff, at most 3 times per `(server, root)`; the fourth failure marks the server
unavailable **for the session**, and that language falls back for good. No alerts,
no banners — ever.

**D8 — `DefinitionCandidate` stops wrapping a `Symbol`.** An LSP definition
response carries a location, not a kind, and a synthetic `SymbolKind` case would
break `SymbolQueryTests`' set equality against the shipped queries. The candidate
therefore stores what it displays and navigates by — `name`, `containerName`,
`kind: SymbolKind?`, `fileURL`, `range`, `line`, `relativePath`,
`isOutsideProjectRoot` — with `displayLabel` byte-identical to before. The
retained `init(symbol:relativePath:)` keeps every *construction* site unchanged;
the stored `symbol` property is gone, so every *accessor* site was a mechanical
edit.

**D9 — The registry.** `LSPServerDescription` is
`{ id, languages, launch, arguments, initializationOptions, configuration,
environment }`, where `configuration` is the per-server settings object D27
delivers (`nil` for all but the YAML server), `environment` is an overlay merged
over the app's own (empty for all but gopls — D17) and `launch` is
`.toolchainTool(name:)` (resolved by the app through `xcrun --find`, honouring
`DEVELOPER_DIR`, cached per app run) or `.executable(path:)`. `LSPServerRegistry`
maps language → description. Adding a server is one registry entry.
**The registry is no longer fixed at construction** (2b's D16): `LSPWorkspace`
holds it as a `var` and `updateRegistry(_:)` swaps it while the app runs, which
is what lets a server installed from Preferences start serving without a restart
— and what stops one that was removed. Phase 2b took that route rather than
touching anything above this file, exactly as this decision promised:
`typescript-language-server` and `pyright` are two `.executable(path:)`
descriptions composed from a pinned manifest, and no client code moved. See
`docs/architecture/core-provisioning.md`.

**D10 — Reader, not writer.** The LSP layer never raises
`autosave.suspend()`/`localChanges.beginRevert()` and is never gated by them — the
same rule already written for the symbol index. It reads buffers and answers
questions; it writes nothing to disk.

**Rename does not change this, and it is worth saying why** (D35/D37):
`textDocument/rename` is a *read* like every other exchange in this layer — the
session verifies nothing, applies nothing and writes nothing — and the
`WorkspaceEdit` it answers with is turned into bytes by the **app**, inside the
seventh writer bracket, through `RenameEditPlan`. The gate stays where the disk
writes are.

**D17 — gopls is discovered, never downloaded, and 2b is not touched.** There are
no official prebuilt gopls binaries; it is distributed as source and installed
with `go install`. So the manifest gains nothing:
`LSPProvisioningManifest`, `LSPInstallEngine`'s *install* path and
`LSPDownloadableServer` are all untouched, and there is no `LSPComponent` for
gopls. What is reused, because it is pure or generic, is the `LSPInstallLayout`
path math (`versionDirectory`/`stagingDirectory`/`contains` are string-keyed and
need no `LSPComponent`) and `LSPInstallEngine.remove(_:)`, which deletes any
component directory on disk whether or not the manifest describes it. So Remove,
the staging sweep and "delete the `LanguageServers` directory to de-provision
completely" all keep working with **zero engine changes**.

**D18 — No new `Launch` case; the app reports a path, Core composes a
description.** The obvious move — a third `LSPServerDescription.Launch` beside
`.toolchainTool`/`.executable` — is the wrong one: everything gopls discovery
knows (`$GOBIN`, `$GOPATH/bin`, `~/go/bin`, the login `PATH`, `/usr/local/go/bin`,
Homebrew) is machine-specific knowledge of exactly the kind D9 keeps out of Core.
Instead the app *does* the search and hands Core a value — "no Go toolchain", or
"`go` at `<path>`, found under `<PATH>`, gopls at `<path>` / not found" — and Core
turns a found gopls into a plain `.executable(path:)` registry entry,
`id: "gopls"`, `languages: [.go]`, no arguments (gopls speaks LSP over stdio by
default), and that `PATH` as the description's `environment`. Core
learns no paths and gains no launch kind. **The `PATH` is part of the answer, not
a detail of the search**: gopls takes no `go` path and resolves the toolchain
itself with `exec.LookPath("go")`, and a Finder-launched app inherits launchd's
`/usr/bin:/bin:/usr/sbin:/sbin`, which contains no Go install anybody ships — so
a report that named only the `go` would register a server that starts and answers
nothing on essentially every machine, silently, with every surface in the app
saying it was installed. Discovery follows the `LSPToolchain`
discipline exactly: non-blocking, off-main, cached per app run **including the
negative answer**, `pending` while unresolved.

**D19 — What is preferred, and the row's two "installed" states.** When both a
user-installed gopls and an app-installed one exist, **the app's own copy wins**:
it is the version this app pinned and the only one Remove may touch, and
preferring the other would make Remove delete a copy that was not in use. The
Settings row therefore reports *no Go toolchain* / *not installed* / *building…*
/ *installed · found on this Mac* / *installed by Pisaka · version 0.23.0* — plus the
`pending` state the lifecycle actually starts in — and offers **Remove only for
the app-installed one**, never for a binary in `~/go/bin` that the app did not put
there. Consent is the existing `LSPServerConsent` under id `"gopls"` in the same
`SettingsStore` dictionary, so declining persists and is reversible from the same
tab, per D15.

**D20 — The install, and where it lands.** Accepting runs
`go install golang.org/x/tools/gopls@v0.23.0` with `GOBIN` pointed at a staging
directory under the app's own install root, then one `move` onto
`…/LanguageServers/gopls/0.23.0/bin/gopls` — D13's atomicity, reused rather than
reimplemented. Nothing global is touched: no `$PATH`, no `~/go/bin`, no `sudo`, no
package manager. Module integrity is Go's own checksum database (`sum.golang.org`,
verified by the toolchain doing the build), their equivalent of 2b's pinned
SHA-256s, so this app hashes nothing itself. Failure philosophy is 2b's verbatim:
silent per-request fallback to tree-sitter, no alert ever, the failure visible
only as the Settings row's sentence plus Retry. Two honest costs come with using
the user's own toolchain and are written down as limits below.

**D21 — Rust is discovery-first *and* downloadable, and it is a third registry
contributor rather than a fourth layer.** rust-analyzer publishes official
prebuilt macOS binaries, so unlike gopls it has a URL, a digest and something to
unpack — and unlike 2b's servers, most Rust users already have one, because rustup
puts a `rust-analyzer` in `~/.cargo/bin`. So it is discovered first and downloaded
second, and it reuses the part of 2b that was already generic and string-keyed: the
pinned `LSPComponent`, `LSPInstallEngine.install(_:)`/`state(of:)`/
`pendingDownloadByteCount(for:)`/`remove(_:)`, `LSPInstallLayout`'s path math, both
seams, D13's stage-then-one-rename and D15's consent record. What it does **not**
reuse is `LSPProvisioningModel`, because Rust's honest state set is the *Go row's*:
it has a toolchain gate and a discovered-copy state no 2b server has, and a row
that offered Install while saying "no Rust toolchain" would be a lie. So
`LSPDownloadableServer` is **untouched** — still `typescript`/`python` — its
set-equality tests go on saying exactly what they said before (asserted unchanged
in `LSPProvisioningManifestTests`), and the Settings row lives beside the Go row in
the toolchain-gated section, with a download size where Go's has none.

**D22 — The second archive format, and the bit `tar` used to carry.**
`LSPArchiveFormat` gains `case gzip(fileName: String)` and loses its unused
`String` raw value. The associated value is where the *name* has to live: a tarball
carries its members' names and a bare `.gz` carries nothing but bytes, and putting
it in a parallel `LSPArtifact.unpackedFileName` would let the manifest express "a
gzip with no name" and "a tarball with one", two states with no meaning that would
each need a guard. `stripComponents` is meaningless for this case and is pinned to
`0` by the manifest tests. The case also carries an implication the other does not
— **a `gzip` artifact is an executable** — and the two halves of the format meet
that implication from both sides: the app unpacker runs `/usr/bin/gunzip` on stdin
with stdout redirected straight into a destination file created with
`posixPermissions: 0o755`, so the ~38 MB is never held a second time in memory and
the bit is set at creation rather than patched afterwards; and the engine then
**verifies it**, asking `FileServicing.isExecutableFile(at:)` after the unpack and
*before* the commit rename, throwing `unpackFailed` if the answer is no. A binary
that arrives unexecutable therefore installs nothing and leaves the previous state
untouched — D13's promise applied to the one thing D13 could not see, an unpack
that "succeeded" and produced something unusable. `FileServicing` gains that method
**without a default**, because a defaulted answer would be either a gate that fails
every install through a partial stub or one that silently passes; the full entry is
in `core-provisioning.md`, where the rest of the bytes are.

**D23 — The toolchain gate and the `PATH` overlay, applied from day one.**
rust-analyzer shells out to `cargo` to build the project model, so without a
toolchain it starts, answers almost nothing, and burns D7's restart budget per
request while the Settings row claims it is installed — the exact failure the gopls
`searchPath` lesson recorded, arrived at one release earlier because that lesson
existed. So: **no `cargo` → no prompt, no consent written, no registry entry,
tree-sitter silently**, for a *discovered* rust-analyzer just as much as for a
downloadable one. When a toolchain is found, the `PATH` that found it travels as
the description's `environment` overlay and Core never learns what is in it (D9).
Discovery follows `LSPToolchain`'s discipline exactly: off-main, non-blocking,
cached per app run **including the negative answer**, `pending` while unresolved.
The `--version` probe applies to a discovered rust-analyzer too, and that is not
symmetry for its own sake: rustup installs a `rust-analyzer` *proxy* whether or not
the component behind it was ever added, so on the single most common Rust setup an
unprobed search finds an executable file that exits non-zero the instant anything
asks it anything — D23's failure with a different first cause.

**D24 — What is preferred, the row's states, the licence, and the pin's shape.**
When both a discovered rust-analyzer and an app-installed one exist, **the app's
copy wins** — D19's argument unchanged: it is the version this app pinned and the
only one Remove may touch, and preferring the other would make Remove delete a copy
that was not in use. The row reports seven states — *looking for a Rust
toolchain…* / *no Rust toolchain* / *not installed (13.2 MB)* / *installing…* /
*installed (found on this Mac)* / *installed by Pisaka · 2026-08-03* / a failure
sentence with Retry — and offers **Remove only for the app's copy**, where it is
the ordinary 2b removal through `engine.remove("rust-analyzer")`. Consent is the
existing `LSPServerConsent` under id `"rust-analyzer"` in the same `SettingsStore`
dictionary, so declining persists and is reversible from the same tab (D15).
Licences: a bare `.gz` ships no licence file, so `licenseFileSubpaths` is empty,
`LSPInstalledLicenses` has nothing to read and `licenses.json` covers nothing —
this app bundles none of its bytes, so the Go decision applies, and the honest
substitute is one sentence in the row naming the origin and the
`Apache-2.0 OR MIT` dual licence (read off the manifest through the row, so the
view's text cannot drift from the pin). The version pin is a **date**
(`2026-08-03`), which is what upstream ships; it sorts correctly
lexicographically, which is the one property `LSPInstallEngine.state(of:)` reads it
for, and it is why this component's pin procedure gets re-run more often than any
other's.

**Three registry contributors now exist**, and the app composes them:
`LSPServerRegistry(provisioning.registry.descriptions + gopls.descriptions +
rust.descriptions)`, awaited through `LSPWorkspace.updateRegistry(_:)`, base
entries first so a hand-registered override still wins, and preserving D16's
push-then-delete ordering for all three — each closure taking its own contributor's
*new* value and reading the other two's published ones. That is glue; every *rule*
about when gopls or rust-analyzer contributes a description lives in the Core model
and is unit-tested there.

**D25 — Hover is answered by a server or by nobody.** `textDocument/hover` is the
third question on `CodeIntelligenceProviding`, defaulted to `nil` in the protocol
extension exactly as `resolveEdits` is — so the tree-sitter provider and both iOS
surfaces are untouched and no existing call site changed. Four rules make it up,
and each of them is a departure from what the other two questions do:

- **No fallback, ever.** `RoutingIntelligenceProvider.hover(for:)` never consults
  the wrapped provider. The index matches *names*; hover asks what something *is*,
  and the only honest source of that is whatever type-checked the file. A
  name-based guess would be indistinguishable from a correct answer while being
  about a different declaration entirely — and this is the one feature nobody
  invoked, so a wrong answer is an interruption as well as a lie. No server, no
  capability, a timeout or an empty answer are therefore one outcome: no popover,
  silently, with no beep and no alert (unlike ⌘-click, which beeps because the
  user asked for something).
- **Empty is not an answer.** `HoverContent` refuses to exist without segments, so
  an optional `HoverAnswer` is the whole vocabulary — a value means "show this",
  `nil` means "show nothing", and there is no third case a caller could get wrong.
  A server answering `{}`, whitespace, or markup that degrades to nothing all land
  in the same place as a server that answered nothing at all.
- **The capability is read before asking.** Every other request would waste one
  round trip on a server that cannot answer; this one runs whenever the pointer
  stops moving, so the wasted round trip is per identifier the pointer crosses,
  forever. `LSPServerCapabilities.supportsHover` gates it, read after `prepare`
  because `prepare` is what produced the capability.
- **Markup is normalized in exactly one place.** A hover reply is the only answer
  in this layer that mixes code and prose in one string, and `HoverContent` is
  where that string becomes segments. The alternative — handing markup to the view
  — puts a Markdown reader in an untested layer and makes "what does the popover
  show" a question with more than one answer.

The budget is completion's 1.5 s rather than definition's 3 s, at both spans
(`LSPSession.Budgets.hover` bounds the exchange, `RoutingIntelligenceProvider`'s
bounds the whole attempt including a cold start): nobody is deliberately waiting,
so an answer that arrives after the pointer has moved on is not late, it is
unwanted. The answer carries the buffer range it describes — the server's own
`range` when it sent one, the identifier under the offset otherwise — because that
is what a caller decides "the pointer is still over the same thing" by, and it is
therefore never absent.

**D26 — The popover is unreachable chrome, and truncates rather than scrolls.**
The macOS panel sets `ignoresMouseEvents = true`, which is one line and buys three
properties at once: clicks, ⌘-clicks, drag-selection and the context menu pass
straight through to the code beneath it; it can never take focus from the editor;
and it is **chrome rather than a code surface** under `ZoomSurface.swift`'s
"unreachable ≡ chrome" rule, so nothing in the hover files declares a zoom surface
even though the panel draws code at the code zone's own font directly over the
text view. A pointer that appears to move "onto" the popover is in fact still over
the text, which simply updates or dismisses the answer, and a zoom gesture aimed
there zooms the code — which is the zone the user means.
Truncation follows from the same line rather than being a separate taste: a
scrollable popover would need the pointer *inside* it, which would undo all three
properties at once. So the cap is pure arithmetic in Core
(`HoverContent.maximumLineCount`, `maximumLineLength`,
`maximumLineUTF8Length` and `maximumInterpretedLineCount`, the drawn count applied
by `truncated(toLineCount:lineLength:)`, the two lengths by the checking
initializer and the interpreted count by `init?(hoverElements:)`) and the panel's only job is to
draw a marker when the content was cut. Anything past a screenful is better read in
the file ⌘-click already opens. The cap bounds **lines and their length, the latter
in characters and in bytes**, because the panel lays the string out synchronously on
the main thread from an automatic trigger: a count that permits a twenty-megabyte
line bounds nothing that matters, and a character count that permits a
twenty-megabyte *grapheme* bounds no more.
`ZoomSourceGatingTests.testTheHoverPanelPassesEveryMouseEventThroughToTheCode`
pins the pass-through and the no-surface half statically, over comment- and
literal-stripped source, because deleting that line changes nothing that compiles,
draws or is otherwise asserted — it only turns the popover into a hit-test
obstacle standing between the pointer and the code.

**D27 — A server's settings are data on its description, delivered on both
channels.** Some servers need to be *told* something before they are useful, and
D9's promise is that such a server costs a data change and no client code. So
`LSPServerDescription` gains one opaque `configuration: JSONValue?` — a settings
object keyed by the configuration *section* the server asks for, `{"yaml": {…}}`
— which `LSPWorkspace` passes at `start` beside `initializationOptions`, and
`LSPSession` delivers. **There is no server-specific code anywhere in the
session**; the value is pinned data on the description, exactly like
`initializationOptions`, and Core has no opinion about its shape.

It is delivered **twice, on both channels a server may take settings on**, because
which one a given server reads is that server's decision and not ours: a
`workspace/didChangeConfiguration` notification carrying `{settings: …}` sent once
right after `initialized` (and never again — nothing in Pisaka changes a server's
settings while it runs), and every `workspace/configuration` pull answered
**section by section** out of the same value for as long as the session lives. A
requested item with no `section`, a section this server's configuration does not
name, and any request at all to a server without a configuration all answer
`null`: absent rather than empty, which is what a server reads as "use your
default". Section names are matched exactly against the top level of the object —
`"[yaml]"` is a section name like any other, not a nested path — so the spelling
the server asks for is the spelling the description must use.

**The pull is the channel that actually matters, and the pin is what makes that a
fact.** Read out of the pinned `yaml-language-server` 1.24.0 bundle rather than
guessed: on `initialized` it calls `settingsHandler.pullConfiguration()`
**unconditionally**, sending `workspace/configuration` for `yaml`, `http`,
`[yaml]`, `editor` and `files` regardless of what the client advertised — and its
`onDidChangeConfiguration` handler ignores the pushed payload and re-pulls. So the
answer to the pull is where the setting lands. The notification is sent anyway,
for servers that read the payload instead — and its cost is stated honestly rather
than assumed: for a server that re-pulls, it is not "one message" but a **second
full pull**, and for this one that means the schemastore catalog is fetched twice
at session start (measured against the pinned bundle: two `catalog.json` requests
with the push, one without). That is the price of not deciding for a future server
which channel it reads; it is one extra request per session, on a session that
already fetches over the network by design (D28).

**A section the description does not name is answered `null`, and `null` is not
always "use your default".** It is for `[yaml]`, `editor` and `files`, which is why
those three stay unnamed. It is *not* for `http`: the pinned bundle folds the
answer into `configure(config.http?.proxy ?? '', config.http?.proxyStrictSSL ??
false)` and hands it to `request-light`, whose module-level `strictSSL` starts
`true` and is only ever lowered by that call — so an unanswered `http` section
reads as "the user asked for `false`" and every schema fetch afterwards goes out
with `rejectUnauthorized: false`. Nothing else protects that traffic: D28's
catalog, schemas and `$schema`-named URLs are unpinned by nature, so a certificate
nobody checks means whoever is on the path chooses what the user's YAML completes
and validates against. The description therefore names `http` with
`proxyStrictSSL: true` (and leaves `proxy` unstated, so `request-light` keeps
honouring `HTTPS_PROXY`/`HTTP_PROXY`), and
`LSPProvisioningManifestTests` asserts that one key on its own.

**The client capability `workspace.configuration` stays `false`.** Flipping it to
`true` would rewrite the handshake for all five existing servers for no gain: a
server that pulls does so either way (this one demonstrably does), and the
capability tree is closed on purpose (D9's neighbour rule — advertise only what is
implemented). Answering a request we did not invite is the same courtesy the file
already extends to `client/registerCapability`: a server blocked on an answer
stalls the request we are waiting on.

**Nothing changes for a server without one, by construction rather than by
promise.** With `configuration == nil` the notification is not sent and every
pulled item is still answered `null` — the two facts the tests pin beside the
positive ones, over `ScriptedLSPTransport`.

**D28 — YAML is the third `LSPDownloadableServer` case, not a fourth
contributor.** Where Go (D17) and Rust (D21) each needed a registry contributor of
their own because their honest state sets are not 2b's, `yaml-language-server` is
exactly a 2b server: a pinned component, downloaded on consent, run by the shared
`node` runtime, with `LSPProvisioningModel`'s existing states describing it
completely. So it is one `LSPComponent`, one enum case (`languages: [.yaml]`,
runtime `node`, `--stdio`, no tsserver path) and one configuration value —
**no new download code, no unpack rule, no path math, and still no npm**. Its
twenty-tarball closure and the `@vscode/l10n` license exception are in
`core-provisioning.md`.

Two things distinguish it from the other two 2b servers, both stated rather than
incidental. Its schemas are **not pinned and cannot be** — it fetches a catalog
from `schemastore.org` and then each schema from the host that catalog names (or
from the URL a file names for itself, in a `# yaml-language-server: $schema=`
header or a top-level `$schema:` key) while it runs, which is what completes a compose file against its real schema — so it
carries the layer's one `runtimeNetworkNote`, printed by the consent banner and
the Settings row before anything is downloaded (`core-provisioning.md`). And it is the one server with a `configuration`, D27's
only user today: `{"yaml": {"schemaStore": {"enable": true}, "completion": true,
"hover": true}, "http": {"proxyStrictSSL": true}}` — the `yaml` half stated rather
than left to an upstream default that happens to agree, the `http` half because an
unanswered section turns TLS certificate validation *off* for all of the traffic
above (D27).

For YAML this replaces nothing — the tree-sitter path knows a document's *keys*,
never its schema, so `ser` in a fresh `docker-compose.yml` could only ever be
answered from luck. Un-consented, removed, or failed, YAML falls back to that path
exactly as every other language does (D7), silently and per request.

**D29 — Notifications arrive on a stream.** `LSPSession` used to drop every
server-initiated notification on the floor; diagnostics are the first thing this
client needs to *hear*. It exposes `notifications: AsyncStream<LSPServerNotification>`,
built at init with one continuation, consumed by `LSPWorkspace` in one main-actor
task per session, attached once `start`'s handshake has succeeded and the session
is filed under its key — the unbounded buffer is what makes that ordering safe,
holding anything the peer says during the handshake until the consumer arrives. A stream rather than a callback because
ordering is the whole point: two pushes for one document ("2 errors", then "all
clear") delivered through two independent `Task { @MainActor }` hops can arrive
backwards, and a callback that published straight into UI state would strand stale
errors under corrected code for the life of the session — a stream is FIFO by
construction, and the single consumer drains it in send order. Buffering is
unbounded because the owner always consumes; finishing the stream is the
crash/exit signal D33's clearing rule reads.

**D30 — The sync is the one thing this layer says unasked.** D2's flush is
request-driven: nothing reaches the server until completion, hover or definition
asks. Diagnostics are push-only, so without an unprompted sync the server would
never re-diagnose anything after its first look at a file. Every open buffer of a
served language is therefore flushed 400 ms after typing stops (per-URL debounce,
superseded by the next keystroke for the same file) and immediately on tab
    open/switch — or when the displayed buffer's *coordinates* change under an
    unchanged id and text: a Save As or a project-tree rename/move (the old URL
    was `didClose`d by the rename's `forgetIndexedBuffer`, and nothing else would
    ever introduce the new one), or a folder change under it, which is the shape
    of the first Open Folder of a run carrying tabs (those buffers were never
    synced at all — every earlier trigger ran with no root, where `prepare`
    answers `nil`). Background tabs stay lazy in every case: they sync on their
    first switch, like every other background buffer, through exactly one
    `LSPWorkspace.prepare(url:language:text:)`
    call with no follow-up request — the whole of D2's machinery (launch coalescing,
    root check, unavailability gate, didOpen/didChange/no-op) already lives inside
    it, so this adds a *trigger*, not a second code path. The sync alone passes
    that call's `forceFlush` flag, and the reason is supply, not politeness: a
    push-only server answers *notifications*, and any other flusher landing first
    (a completion at 150 ms, a hover) has already delivered the same text without
    leaving an accepted push behind — its version moved past the model's record,
    so the gate rejected the publish it provoked. An unforced settling sync would
    then find nothing to send and nothing coming, freezing all three surfaces at
    the pre-typing state; one redundant full-text `didChange` (bytes identical,
    version bumped) is what makes the burst always end in a notification the
    server must answer and the gate can accept. The cost is one extra whole-file
    `didChange` only in exactly those bursts — the ordinary settle still sends
    one. One consequence is stated rather than hidden:
    opening a served file now launches its server, where before a completion or a
    ⌘-click was needed — that is what "diagnostics on open" means, and consent-gated
    servers still sit outside the registry until consented, so nothing new starts
    without the same gates every other launch has.

**D31 — Diagnostics are anchored to the text the server was told.** A push is
mapped through `LSPPositionMap` against `documents[uri].text` at receipt, accepted
only when the pushing key's root is the folder this workspace **currently** serves,
the URI names a document that `(server, root)` currently holds, **and**
its `version`, when present, equals the version last flushed for it; a push for a
URI nobody holds open is ignored (the surfaces cover open documents only), and so
is one whose URI does not parse as a URL — the round-trip to `URL` happens once,
here at the boundary, because everything downstream speaks `URL`. The
live buffer is deliberately *not* consulted: the editor may already have moved on,
and remapping against it here would guess. What happens instead is D32.

**D32 — Stale means shifted, and what the edit touched is dropped.** Between the
push that produced a set and the next one, each edit runs `DiagnosticShift`:
entirely before the edit — unchanged; entirely after — shifted and renumbered;
intersecting the touched span — dropped. The error being fixed loses its underline
on the first keystroke while errors elsewhere stay anchored, rather than drifting
(no shift) or blinking off on every keystroke (a blanket clear). A wholesale
*replacement* of one document's buffer (`reloadFromDisk`, project Replace All,
merge apply — including the off-screen case, which `externalTextRevision` reports
at the next switch) drops that document's set outright. A **plain tab switch is
not a replacement**: the store is keyed by URL precisely so background documents'
sets survive the view swap — dropping them would strand them, because the
switch-back sync takes D2's identical-text fast path and a push-only server never
re-publishes unasked. The swap's full-range edit is kept out of the shift for the
same reason (the coordinator ignores it while it is in flight). On the receive
side the model refuses a push whose document was edited since the sync that
produced it: the buffer revision pinned synchronously at each sync must still be
current, so a push computed against moved-
past text is dropped, never replayed against an edit log — with one carve-out,
the **hold-and-reconcile step**: the workspace commits a flushed version several
main-actor hops before the controller's report lands, and a fast server's answer
can be routed inside that window, where dropping would strand the document blank
until the next interaction. A push that finds no record, or a record pinned to a
moved-past revision, is held (one per document, newest wins) and judged by the
next report; everything that invalidates state — edits, replacements, clears,
folder changes — drops holds too. A version mismatch against a *current* record
is **held as well**, not dropped: with no keystroke to condemn it the push is
either a late replay, which the reconcile's version half then discards, or the
settling flush's own publish arriving ahead of its report, which the reconcile
admits. Holding costs nothing, because only the version the record actually lands
with is ever accepted. **Rejected:** the exact
alternative — queueing edits and replaying them onto a late-arriving push — needs a
bounded per-document edit log and a revision↔version map; dropping is simpler,
self-correcting (the last keystroke always schedules one more sync whose push has
no edits after it — and that sync *forces* its notification past D2's no-op, so
the correction does not silently depend on nobody else having flushed first), and
matches the preference for briefly missing over misplaced.

**D33 — A server's diagnostics die with it.** Clearing is keyed by `(server, root)`
and emitted on every teardown path — `noteDeath`, `shutdownAll`,
`terminateNow`, `updateRegistry`'s removals, and both sites that retire a key into
`unavailable` (a spent D7 budget, and a server disqualified for not speaking UTF-16,
which never counts a failure at all) — plus per-document on `didClose(url:)`.
Clearing is **at-least-once and idempotent**, never exactly-once: one crash can emit
up to three clears for the same key (`noteDeath`, the fourth-failure retirement, and
the consumer walking out of a finished stream), which is deliberate — every sink
must absorb a duplicate, and a clear that finds nothing to clear is the cheap half
of never leaving a dead server's squiggles on screen. The externally-killed server has no
deliberate path, so it is covered by the *stream's* termination: the session's read
task hits EOF, `close(reason:)` finishes the notification stream, the workspace's
consumer task walks out of its loop and emits the key's clear on the way out. That
path tears no session down and touches no D7 counter — noticing a crash stays
`prepare`'s job — but it must not clear a *replacement* server's fresh pushes
either, so the consumer checks that no newer session owns the key before clearing.
In practice that check is a backstop: every site that empties or replaces the slot
cancels the incumbent consumer inside its synchronous mutation prefix, so an
exiting consumer normally stops at `!Task.isCancelled` before the identity check —
the reachability finding
`testAReplacementOpenedWithoutWaitingIsNotClearedByThePredecessor` stages and
records, alongside the unwaited neighbourhood the check still guards.
Without all of this, a dead or removed server's squiggles would sit on screen until
the file was edited — the one state in this layer that outlives its author.

**D34 — Hover carries the diagnostic message; there is no second surface.** A
pointer resting inside a diagnostic wants the message, and building a second
popover type for it would duplicate the dwell, the panel, the dismissal set and
the cap machinery for no new information. So the existing pipeline shows them:
`Diagnostic.hoverContent(for:merging:)` renders the messages as severity-labelled
prose above the type answer when there is one and alone when there is not, through
the same checking initializer so D26's caps apply once. Two changes follow, both in
the view layer (`app-editor.md`): the dwell fires inside a diagnostic range even
when the pointer is not over an identifier (a diagnostic can cover punctuation),
and the anchor becomes the union of the diagnostics hit rather than the identifier,
so jitter within diagnosed text neither re-asks nor dismisses. D25 is untouched —
a diagnostic comes from a server, so this is still "a server or nobody" — and D26's
pass-through-chrome rule still governs the popover itself.

**D35 — Rename is answered by a server or by nobody, and it is the one question
here that writes.** `textDocument/rename` has **no tree-sitter fallback and no
textual one**. D25's reasoning, restated where the stakes are higher: hover has no
second answer because the index knows names and not types; rename has none because
the only second answer available — replace every whole-word occurrence — is
indistinguishable from a correct rename until two symbols share a spelling, and
then it has silently rewritten the one nobody was looking at, in files the user
never opened. There is no alert and no banner when it is unavailable: the menu item
stays enabled whenever a tab is open, the command pre-checks `canRename(_:)`
(policy-only, free, starts nothing) and **beeps without showing the sheet** when
that is false, and a server that turns out to advertise no `renameProvider`, or
answers with no edits, beeps after the request. Enabling the item on a *capability*
would mean starting a server to decide whether a menu item is a menu item; greying
it out would mean explaining, in a menu, a reason a menu cannot state. The rest of
the rename — the plan, the five refusals, the verification and the disk/buffer
split — is `RenameEditPlan`'s entry above, and the writer bracket that applies it
is the app's seventh (`core-local-history.md`, `app-shell.md`).

**D36 — The textual usages answer is a *model* decision, not a provider
fallback.** `CodeIntelligenceProviding.references(for:)` is LSP-or-nothing, exactly
like hover: an index of declarations cannot enumerate references, because a
reference is not declared anywhere and nothing in a `symbols.scm` capture names
one. But unlike hover, an empty answer here is **not the end of the question** —
there is an honest second answer, `TextualUsageScanner`'s whole-word scan, which
claims far less and says so in the panel. It is not run in
`RoutingIntelligenceProvider` for two reasons that would each be enough. It costs a
**walk of every file in the project**, and the router's contract is a deadline race
whose loser is abandoned where it stands — a walk abandoned mid-flight leaves
nobody to say so and nothing to show. And the walk needs the file service, the
gitignore rules and the open buffers, none of which the provider chain has or
should acquire. So `FindUsagesModel` runs it, where all three already live, and the
panel is told which of the two answers it is holding (`UsageProvenance`). The rule
that follows and is worth stating because it is the *inverse* of D6's: **nothing in
the provider chain ever walks the project.**

**D37 — The document version is decoded and never compared; the text is.** A
`WorkspaceEdit`'s `documentChanges` entries carry an optional
`OptionalVersionedTextDocumentIdentifier.version`, and this client keeps it and
compares it to nothing. Comparing versions would only catch the servers that
bothered to number, and would still say nothing about a file **no editor holds** —
which a project-wide rename routinely rewrites, and whose version this client has
never issued. So the check is the bytes: every `RenameEdit` carries the
`expectedText` its range held when the plan was built, and the whole plan is
re-verified against the current text of every file it touches *inside* the writer
bracket, after the Local History capture and before the first write. That catches
everything a version would (the user typed, a git operation ran, another editor
saved) plus everything it would not, and it is what makes the rename all-or-nothing
in the only place that matters — up to the first byte written. The order inside the
bracket is capture, verify, write, and it is that way round on purpose: the capture
must be the first `await` in the bracket for the Local History invariant, and
verifying first would leave a window between the verification and the capture in
which the thing verified could change. An aborted rename therefore leaves one
harmless extra snapshot behind, which retention prunes.

**D38 — `textDocument/foldingRange` is the seventh question, and the first one
about a whole document.** Every other request in this client points at a
position: an offset, an identifier, a caret. This one names a document and
nothing else (`LSPFoldingRangeParams` is a `textDocument` identifier), because a
chevron per header line is a property of the file rather than of wherever the
user is standing — the editor asks once per typing pause and holds the whole
list. It is also the first question whose second answer is **as good as the
server's for most files**: `FoldRegionScanner` says where a block is from
brackets and indentation without knowing what it means, so unlike hover (D25) and
rename (D35) this one never ends here, and unlike references (D36) its second
answer is a *provider's* own rather than a model's — it costs one pass over the
text already in the request and walks nothing. The whole feature is documented in
`core-folding.md`; what belongs here is the wire.

*The decode table is closed and the open field is read as absence.*
`LSPFoldingRange` requires only the two line numbers. Both characters are
optional because the specification types them so, and **their absence means
exactly what this editor wants**: no `startCharacter` is "from the end of
`startLine`'s content", no `endCharacter` is "to the end of `endLine`'s content",
which is the hidden range the fold engine needs anyway — so a line-oriented
server and a character-precise one are one code path. The provider then
floors the start at `startLine`'s content end: `FoldRegion` promises the
header line stays visible in full, and a server naming the start of the
folded *node* (column 0 of an import group's first item, the `//` of a
comment run, the `{` of a block) would otherwise hide the header's own text
— leaving a numbered row showing nothing but the placeholder, a caret
clicked into that text ejected by `FoldCaretRule`, and `FoldReveal`
springing the block open for a range that is already visible. It costs a
line-oriented answer nothing, and costs a character-precise one nothing at
the end bound, which is where that precision buys something. `kind` is read
through the closed `FoldRegionKind` table
(`comment`/`imports`/`region`), and a string that table does not name decodes as
**absent rather than as a refusal**, because `FoldingRangeKind` is explicitly open
and a block carrying a word we do not know is still a block. Nothing branches on
the kind yet; it is carried because dropping a fact the wire already stated would
only have to be undone later.

*The three drops, and the one throw.* `LSPFoldingRangeResponse` states
`LSPReferencesResponse`'s three rules for its reasons: `null` and an absent
`result` are one empty answer; one unreadable element is dropped while its
siblings survive (a server that miscounts one block must not cost the file every
other fold); and a top level that is neither `null` nor an array still **throws**,
because "this file folds nowhere" and "we could not read the answer" are different
facts and only the second should send the editor back to its own scanner. The
provider drops two more shapes for the same reason it drops one bad element: a
start line past the end of the document, and an end before its start. Both are a
server miscounting one block, which must cost that block a chevron and cost the
file nothing else.

*The budget.* `LSPSession.Budgets.foldingRange` and
`RoutingIntelligenceProvider.Budgets.foldingRange` are both **completion's
number**, for completion's reason read one step further: nobody *asks* for a fold
list — it is computed behind a typing pause — so the next keystroke makes an
answer stale rather than merely late. It is also the cheapest expiry in either
table, because the pure scanner answers the same question over the text already in
hand. The two spans are the usual pair: the session's bounds the server's part of
one exchange, the router's the whole attempt.

*The capability node.* The handshake advertises `textDocument.foldingRange` with
`lineFoldingOnly: false` — the editor hides a UTF-16 range, not a set of whole
lines, so a server that would otherwise round every block out to line granularity
is told it need not — and `foldingRange.collapsedText: false` for the mirror-image
reason: the placeholder is always `…`, so a server-supplied one would be a string
received and thrown away. `dynamicRegistration` is `false` like every other node,
and `foldingRangeKind.valueSet` is the closed `FoldRegionKind` table spelled on the
wire. On the server side, `foldingRangeProvider` is `boolean |
FoldingRangeOptions | FoldingRangeRegistrationOptions` — three spellings, one
question — read through the same presence collapse every provider above it uses,
into `LSPServerCapabilities.supportsFoldingRange`. Unlike hover and rename, a
server that does not advertise it costs the file **nothing but the round trip that
is now never sent**: the scanner answers instead.

*The header line is the editor's, the bounds are the protocol's.* The provider
builds two line tables per answer — `LSPPositionMap.lineStarts` for the numbers
the server named, `LineStartIndex.offsets` for the line the chevron lands on — so
D1's separator divergence is settled at the boundary and cannot reappear as a
drifting chevron. Everything downstream (`FoldShift` included) is in the editor's
numbering only.

## Known limits

- **NEL / U+2028 / U+2029 line separators.** In a file delimited by those, the
  editor's line count and the server's differ (D1). Offsets — and therefore every
  jump and every edit — stay exact, because every LSP position is converted to an
  absolute offset at the boundary; only the two *numberings* diverge, and no LSP
  line number is ever shown raw. Asserted by
  `LSPPositionMapTests.testUnicodeSeparatorsDivergeFromTheEditorsLineCount`
  rather than left as an assumption.
- **The interior of a CRLF pair is not an addressable LSP position.** Both
  mapping directions clamp it to the line's content end.
- **Late auto-import is a second undo step** (D4), and is skipped entirely if the
  buffer changed between the insertion and the resolve landing.
- **D4's auto-import was unobservable in 2a, and is not any more.**
  sourcekit-lsp offers no unimported symbols, so nothing it sends — resolved or
  not — has ever carried `additionalTextEdits` (recorded in the fixtures'
  `README.md`, which is why `completion-auto-import.json` is authored to the spec
  rather than captured), and the rule and its geometry are pinned by
  `CompletionEditPlanTests` and `LSPIntelligenceProviderTests` alone. **Phase 2b
  changes that**: both `typescript-language-server` and `pyright` return
  auto-import completions carrying `additionalTextEdits`, so with either
  provisioned this path fires for real and is the primary way it is exercised. The
  manual check "completing a symbol that needs an import inserts the import line"
  therefore belongs with the provisioning checks, and an import that does not
  appear *is* a regression.
- **sourcekit-lsp answers for projects it can build.** It resolves a build system
  from the root it is initialized with — a `Package.swift`, a
  `compile_commands.json`, an `.xcodeproj` through the build server protocol. A
  loose folder of Swift files is not one of those: the server starts, answers
  little or nothing, and every request falls back to the index. That is a silent,
  per-request degradation by construction, not a state the user is told about.
- **macOS only.** iOS installs no routing provider and no registry, so it is
  literally the tree-sitter index — there is no subprocess on iOS to run a server
  in.
- **Hover has no fallback and no setting** (D25). A language with no server shows
  no popover at all, and there is nothing to turn on: unlike completion, which has
  a lightbulb and a preference, hover is either answered by a server or absent.
  Nor is it offered from the keyboard — the dwell *is* the trigger — so a file
  read without a mouse never sees it.
- **A hover popover is a glance, not a document browser** (D26). Content past
  `HoverContent.maximumLineCount` lines — or past `maximumLineLength` characters
  (or `maximumLineUTF8Length` bytes) on any one of them — is cut and marked with an
  ellipsis, code
  lines wider than the panel are truncated rather than wrapped (a wrapped
  signature invents indentation the language never had), the panel's height is
  additionally capped at the screen (the line cap counts logical lines and prose
  wraps, so it alone does not bound the drawn height), and none of it can be
  scrolled, selected or copied, because the panel passes every mouse event
  through. The full text is in the declaration ⌘-click opens.
- **Markup is degraded, not rendered — but never *altered*** (D25). `HoverMarkup`
  reads the narrow dialect hover answers are written in — fences, paragraphs,
  lists, links — and drops what a two-font popover cannot draw: emphasis,
  headings' `#`, rules, HTML tags, link URLs. Tables and block quotes are not
  modelled: their `|` and `>` reach the popover as ordinary text, which is the
  degradation this rule promises rather than a rendering bug. The bound on the
  degradation is what the reader departs from CommonMark for: a construct is
  dropped only when it is unambiguously markup, so `Vec<u8>` keeps its parameter,
  `w*h` and `_private` keep their delimiters and `C#` keeps its `#`. **Losing a
  character of a name is a wrong answer, not a plain one**, and it is the one
  failure a popover whose whole job is naming things cannot have.
- **No Xcode, no server.** `xcrun --find` answering nothing is an ordinary
  outcome: one restart is spent, the negative result is cached for the app run,
  and Swift files behave exactly as they did before this phase.
- **gopls needs a Go toolchain, and there is no offer without one** (D18). On a
  Mac with no `go`, nothing is prompted, nothing is installed and no description
  is contributed — Go files highlight, index, complete and jump from the
  tree-sitter index exactly as they do for a user who declined. The same is true
  of a `go` that cannot answer `go env`: it is reported as *no* toolchain rather
  than as one with an unknown `GOBIN`, since it will not build anything either.
- **The build writes into the user's `GOMODCACHE`/`GOCACHE`** (D20). That is what
  `go install` *is*; only `GOBIN` is redirected. The alternative — a private
  `GOPATH` under the install root — would re-download and rebuild the module
  world for no benefit, and would then be invisible to `go clean -modcache`. So
  the installed *binary* is entirely this app's, while the intermediates are the
  user's, and Remove deletes the first and leaves the second.
- **`GOTOOLCHAIN=auto` may fetch a newer toolchain to build with.** That is Go's
  default behaviour, not something this app asks for: if the module requires a
  newer Go than the one discovered, the discovered one downloads it. The install
  therefore is not strictly "no network beyond Go's module proxy" on such a
  machine, and it is stated rather than papered over.
- **A user-installed gopls is used at whatever version it is.** It is discovered,
  not measured: no version is read, none is required, and none is shown beyond
  "found on this Mac". A stale one answers as well as it answers, which is the
  same contract every language server here has — and it is never replaced,
  because the app's own copy would then be the one Remove deletes while the other
  went on running.
- **Discovery is per app run, not per folder** (D18). A Go toolchain installed
  while Pisaka is running is picked up at the next launch. Stated rather than
  papered over with invalidation logic for an event nobody has hit.
- **No gopls on iOS, ever.** iOS has no subprocess, so there is neither a `go` to
  discover nor a server to run — the same reason phase 2a is macOS-only, and it
  is structural rather than a phase boundary.
- **rust-analyzer needs a Rust toolchain, and there is no offer without one**
  (D23). On a Mac with no `cargo`, nothing is prompted, nothing is downloaded and
  no description is contributed — Rust files highlight, index, complete and jump
  from the tree-sitter index exactly as they do for a user who declined. The same
  is true of a `cargo` that cannot answer `cargo --version`, and of a
  rust-analyzer that cannot answer it either: both are reported as *absent* rather
  than as present-but-broken, because a rustup proxy whose component was never
  added is a file that exists, is executable, and fails the moment it is asked
  anything.
- **A discovered rust-analyzer is used at whatever version it is.** It is
  discovered, not measured: no version is read, none is required, and none is
  shown beyond "found on this Mac". It is also never replaced or upgraded by this
  app — Install is refused over it — because the app's own copy would then be the
  one Remove deletes while the other went on running.
- **A pin bump on a Mac that also has a discovered copy falls back to the
  discovered one rather than re-downloading.** `installation` answers
  `.appInstalled` only for the *pinned* version, so the moment an app update moves
  the pin, the app's own tree stops being the answer and the discovered copy wins
  by default — the row flips from "installed by Pisaka · <date>" to "found on this
  Mac", `prepareForOpening` sees a non-`nil` installation and installs nothing, and
  the superseded directory stays on disk until Remove or the next successful
  install reclaims it. That is D24's preference rule applied consistently (the
  app's copy wins *when it exists at the pin*), and it is a limit rather than a
  bug because the alternative — re-downloading over a working server the user
  already had — is the louder wrong answer. Recorded in `README.md` too, since it
  is the one case where the promised "the next Rust file re-downloads at the new
  version" does not happen.
- **Discovery is per app run, not per folder** (D23). A Rust toolchain installed
  while Pisaka is running is picked up at the next launch, stated rather than
  papered over with invalidation logic for an event nobody has hit.
- **No rust-analyzer on iOS, ever** — gopls's limit for gopls's structural
  reason: iOS has no subprocess to discover a `cargo` with or to run a server in.
- **`.rs` files have no ⌘R.** `TestCommand` answers `cargo test` for Rust, but
  `RunCommand` deliberately has no `rs` entry: its map answers a command for a
  *single file* and appends the quoted path, which `cargo run` cannot take. Rust
  has a project-level runner and no file-level one, so ⌘U works and the terminal
  panel is the answer for ⌘R. Pinned by `RunCommandTests` rather than left as an
  omission; the reasoning is in `core-services.md`.
- **Diagnostics cover open documents only, and only what a server said last.**
  A push for a URI no server holds is dropped (D31), so a file closed mid-typing
  loses its squiggles until reopened; there is no project-wide problems list of
  things no server was ever asked about. Between pushes the shown state is
  maintained by shift-and-drop (D32), which is exact for edits outside a
  diagnostic and deliberately silent about the one it intersects — an underline
  vanishing under the caret until the next 400 ms sync's push lands is the design,
  not a bug. A document whose pushes are all rejected while its buffer keeps
  moving shows nothing rather than something stale; the next settled typing pause
  re-syncs and repopulates.
- **Diagnostics have no setting and no iOS surface.** Like hover (D25), they are
  either answered by a registered server or absent, and absence is expressed by
  un-registration or consent, never by a second flag. The three surfaces —
  squiggles, gutter markers, the Problems panel — are macOS-only; iOS has neither
  servers nor a bottom dock.
- **A diagnostic's line number can disagree with the gutter by D1's amount** in a
  file delimited by NEL/LS/PS: the stored `line` counts LSP separators, the ruler
  numbers the editor's wider set. Nothing prints the two side by side without
  going through the ruler's own geometry, so the divergence stays invisible; the
  panel's `:N` suffix reads the store's zero-based line plus one, which in such a
  file may differ from the gutter's number on the same row.
- **A rename is not undoable as a unit** (D35, decision 5). Only the tab that is
  on screen when the rename is applied gets one undoable step; every other open tab
  is rewritten through `WorkspaceModel.replaceText(_:for:)` and loses its undo
  stack, exactly as an off-screen save transform does, and a file no tab holds
  changes on disk with no undo at all. The recovery story is Local History's
  "Before Rename" revision, which is why that event exists — a **safety net and not
  a guarantee**: the capture reads at most `LocalHistoryPolicy.maxPreOperationFiles`
  (200) files from disk and skips binary and oversize ones silently, so a rename
  touching more than that has revisions for only the first 200. The
  "Rename incomplete" alert is worded for that, and for the other half of the same
  story: `apply` stops at the first write that throws, so the files it had not
  reached still hold the old name while every open buffer has been rewritten
  regardless. Cross-file undo is a follow-up, not a hidden intention.
- **There is no rename preview and no `prepareRename`.** What a rename will change
  is knowable only after the server has answered, and it is applied without showing
  the user that list; there is likewise no way to opt one file out. Both are
  follow-ups recorded on `RenameEditPlan`'s entry.
- **A usages answer is a snapshot, and a row can go stale.** Rows are positions in
  texts that were read once, and nothing re-runs the query when a file changes — a
  walk per keystroke is not a trade worth making. Activation therefore checks the
  bytes (`UsageResult.revealRange(naming:in:)`) and degrades to opening the file
  with nothing selected when the range no longer spells the identifier, which also
  means a semantic row whose server answered with a range *wider* than the name
  degrades even when nothing changed. Every server this app speaks to answers with
  the name's own range, so that is theoretical; the direction it fails in is the
  one that cannot mislead.

## Test fixtures

Recorded `sourcekit-lsp` transcripts live in `Tests/PisakaCoreTests/Fixtures/LSP/`
and are read through `#filePath` like the other repository-file suites — no
SwiftPM resource declaration, and **no live process is ever spawned by
`swift test`** (`Package.swift`'s test target carries an `exclude:` for the
directory so SwiftPM emits no unhandled-resource warning).

They were recorded from a live `sourcekit-lsp` (Xcode 26.6) driven over a
throwaway two-module SwiftPM package, not hand-written from the specification;
`Fixtures/LSP/README.md` records the provenance of each file. Two shapes that
server would not produce — `LocationLink[]` (it answered `Location[]` from every
position tried, even with `linkSupport` advertised) and a completion item carrying
`additionalTextEdits` (it offers no unimported symbols, so it never emitted one) —
are authored to the spec and labelled as such in that README rather than passed
off as recordings.

`Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift` is the deterministic
fake every session and workspace test drives: a script of replies, delays, drops
and stream closures, with no real process anywhere. `onSend(_:)` is its one
*interleaving* seam — called synchronously from `send`, on the session's writer
thread, so a test that blocks in it holds the writer inside a notification while
the main actor is free to run something else. That is the only way to stage the
window `flush`/`didClose` claim a document against deterministically (`Gate`'s
principle, one layer down). Since D29 it also speaks *unprompted*: `push(method:
params:)` makes the fake server emit a server-initiated notification at any
moment, and `pushAfter(delay:method:params:)` delays one so two pushes can be
ordered against other traffic without depending on scheduler luck — which is how
the notification stream's ordering, finishing and malformed-payload tests are
written.
