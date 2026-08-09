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

**Where the platform boundary is.** All of it is in `PisakaCore` except one
thing: the `Process` and its three pipes, which live macOS-gated in
`Sources/Pisaka/LSPProcessTransport.swift` behind the `LSPTransport` protocol.
That is exactly the `GitServicing`/`GitCLIService` split, for the same reason —
framing, correlation, budgets, position mapping, restart policy and ranking all
stay testable in a target that cannot spawn a process. `LSPSourceGatingTests`
enforces the split statically: no `Sources/PisakaCore` file of this layer may
mention `Process`, `AppKit`, `UIKit` or `SwiftTreeSitter`, and every app-side file
of it must be wrapped in `#if os(macOS)`. Files are *discovered* by a per-side
prefix list (`LSP`, plus `SourceViewer` in the app and
`CompletionEditPlan`/`RoutingIntelligenceProvider` in Core — the layer's members
that are named for what they decide rather than for the protocol), and the
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
`CompletionEditPlan` hangs off the side of the last two: it is the pure rule the
editor applies an auto-import with.

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
    `contextSupport` and `resolveSupport` for `additionalTextEdits`/`detail`, and
    **no** `snippetSupport` (D5).
    `LSPServerCapabilities` models only what this phase acts on; everything else a
    server advertises is ignored rather than typed, since twenty providers we never
    call are not information. `definitionProvider`/`completionProvider` are
    `boolean | Options` on the wire and both spellings collapse to one question
    (an options object *is* support). `usesUTF16Positions` is the one capability
    that can disqualify a server outright — see D7's terminal failures.

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
    difference between a clean exit and a SIGTERM). A request that outlives its
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
    error it might treat as fatal), `workspace/configuration` gets one `null` per
    requested item (Pisaka has no per-server settings surface, so "no setting" is
    exactly true), and anything else gets `MethodNotFound`. Notifications are
    ignored — diagnostics, logs and progress are all noise here, and ignoring an
    unknown one is what the spec asks for anyway.
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
    when it does not. A document is never opened against a root it does not live
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
    Neither generation moves either: a registry update is
    not a folder change, and a request in flight for a server that survived is
    still a request about the folder it was asked under. Every map a `prepare`
    reads is emptied *before* the first hop, `shutdownAll()`'s ordering applied to
    a subset — `transports` excepted, for the reason above, and harmlessly so
    since no reader consults it. An equal registry returns immediately.
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
    stable), then only hygiene — drop the item that claims snippet format, drop the
    item identical to what was typed, collapse
    duplicates by inserted text (first wins), cap at
    `SymbolIntelligenceProvider.defaultCompletionLimit`.
    **The snippet drop is enforcement, not tidiness.** D5 advertises
    `snippetSupport: false`, but a client capability is a *request*: a server that
    ignores it answers with `insertTextFormat: 2` and a `newText` full of
    `${1:…}` placeholders, and a completion item is the one thing in this layer
    whose result is written to the user's file rather than merely displayed. So the
    field is read, not just decoded: absent means plain text (the spec's default)
    and is kept, anything other than `1` is dropped, by the same rule as everything
    else here — no answer is better than a guessed one.
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
    so the output for Markdown, YAML, a scratch buffer or a machine with no
    toolchain is *the wrapped provider's output*, byte for byte —
    `RoutingIntelligenceProviderTests` pins that by equality on both request kinds
    rather than by inspection, because "phase 2a changed nothing for the other
    eleven languages" is the promise most worth being unable to break by accident.
    **An empty answer is not an answer**: a server returning no definitions where
    the index has one has failed to answer the question, so an empty LSP result
    falls through, and only an empty result from *both* is empty — the case the
    editor beeps at, once.
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

**D5 — No snippet support is advertised**, so `newText` is always plain text and
nothing has to strip `${1:placeholder}` syntax. Advertising it is not the same as
being obeyed, though, so the guarantee is *checked* as well as asked for:
`publish` drops any item whose `insertTextFormat` is present and not `1`, rather
than writing placeholder syntax into the buffer on the word of a server that
ignored the capability.

**D6 — Ranking for LSP-answered requests trusts the server**: items sorted by
`sortText ?? label`, preserving server array order on ties, then the existing
hygiene (drop the snippet-format item, drop the item identical to the typed
token, dedup by inserted text, cap
at `SymbolIntelligenceProvider.defaultCompletionLimit`). No name heuristics on
top. The recorded transcript is what pins this rather than a constructed example:
sourcekit-lsp put `Greeter` *last* in the array with the *lowest* `sortText`.

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
`{ id, languages, launch, arguments, initializationOptions }`, where `launch` is
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
- **No Xcode, no server.** `xcrun --find` answering nothing is an ordinary
  outcome: one restart is spent, the negative result is cached for the app run,
  and Swift files behave exactly as they did before this phase.

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
principle, one layer down).
