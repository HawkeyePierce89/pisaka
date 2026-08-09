# PisakaCore — language-server provisioning (phase 2b: TypeScript/JavaScript and Python)

Design documentation for the layer that downloads, verifies, installs and
un-installs the language servers the app did not ship with. Each entry records a
file's contract, invariants and the reasoning behind non-obvious decisions — read
the relevant entry before modifying that file, and update it when behavior
changes.

**What this layer is.** A pinned manifest of downloadable components, an install
engine that turns one of them into a directory of verified files, per-server
consent, and dynamic registration into the LSP client's registry — so that
`typescript-language-server` (TypeScript/JavaScript) and `pyright` (Python)
become live `.executable(path:)` entries the moment they install, with no
restart. Phase 2a's client (`docs/architecture/core-lsp.md`) is what then *talks*
to them; this layer only decides that they exist.

**Nothing new is bundled and nothing new is linked.** `project.yml`,
`Package.resolved`, `Resources/Licenses/licenses.json` and every dependency pin
are untouched by this phase: the servers arrive over the network at the user's
request or not at all. There is no `npm`, no lockfile and no dependency solver —
`typescript-language-server@5.3.0` has no runtime dependencies and
`pyright@1.1.411` has exactly one optional one, so the whole closure is the six
artifacts the manifest names.

**Where the platform boundary is.** Everything decision-shaped is in
`PisakaCore`, Foundation-only and unit-tested: the manifest, the digest, the path
math, the staging/rename sequence, the consent rules and the registry
composition. Two things Core cannot do are macOS-gated app files behind
protocols — fetching bytes (`LSPArtifactDownloading` → `LSPDownloadService`) and
expanding an archive (`LSPArchiveUnpacking` → `LSPArchiveUnpacker`) — exactly the
`LSPTransport`/`LSPProcessTransport` split, for the same reason: `swift test`
needs neither a network nor a `tar` to exercise the part with the decisions in
it. `LSPSourceGatingTests` enforces the split statically over both sides by set
equality, and `SHA256` is swept by it too, so a later `import CryptoKit` fails
the suite rather than the portability promise.

**The stack, bottom to top.** `SHA256` (bytes → digest) →
`LSPProvisioningManifest` (what may be downloaded) + `LSPInstallLayout` (where it
goes) → `LSPInstallEngine` (download, verify, unpack, rename) →
`LSPProvisioningModel` (consent, rows, and the registry that comes out) →
`LSPWorkspace.updateRegistry(_:)` (which servers may now be started, and which
must stop).

The decisions D11–D16 are written out at the end of this document, together with
the pinned manifest, the by-hand update procedure and the limits the design
carries. D1–D10 are in `core-lsp.md`.

**gopls is not one of these, and there is no gopls artifact to look for.** The Go
language work added a *second* registry contributor beside this one, and it
deliberately reuses only the half of this layer that is not about bytes. It
**does** reuse `LSPInstallLayout`'s path math (string-keyed, so it needs no
`LSPComponent`), `LSPInstallEngine.remove(_:)` (which deletes any component
directory on disk whether or not the manifest describes it), the same install
root and therefore the same `sweepStaging()`, D13's stage-then-one-rename
atomicity, D16's push-then-delete removal ordering, the `LSPServerConsent`
dictionary in `SettingsStore` under one more id, and both surfaces below — the
consent banner and the Language Servers tab. It **does not** touch
`LSPProvisioningManifest`, `LSPDownloadableServer`, `LSPComponent`, `SHA256`, the
two download/unpack seams, or `LSPInstallEngine`'s install path: there are no
official prebuilt gopls binaries, so there is no URL, no digest, no archive and
nothing to unpack — it is discovered if the user already has it, and otherwise
built by the user's own Go toolchain. All of it, with decisions D17–D20, is in
`core-lsp.md`.

## Files

### `PisakaCore`

  - `SHA256.swift` — FIPS 180-4 SHA-256 over `Data`, with a lowercase-hex
    convenience. It exists because the *only* thing standing between a pinned
    manifest and whatever the network handed over is a checksum comparison, that
    comparison is a Core decision, and Core may not import `CryptoKit` — so the
    digest is written here rather than borrowed.
    Deliberately the textbook algorithm: 64 rounds over a 16-word schedule, no
    table tricks, no unrolling, nothing beyond the `&+`/`&<<` the specification's
    mod-2³² words require. It hashes ~50 MB once per install on a background hop,
    so being obvious costs nothing next to the download it verifies — and being
    obvious is what makes the published-vector tests a real check rather than a
    re-derivation of whatever this file happens to do.
    **The incremental shape is the honest one.** The engine hashes exactly one
    `Data`, so `digest(of:)` would be enough; but a one-shot-only implementation
    hides its padding in a path no test can vary, and every interesting SHA-256
    failure is at a block boundary (a message ending at 55, 56, 63 or 64 bytes
    takes three different padding routes). `update`/`finalize` is what makes
    "feed the same bytes in different-sized pieces, demand the same answer"
    expressible. `finalize` may be asked twice and answers the same digest, since
    it caches rather than re-padding.
    `SHA256Tests` runs the published vectors — empty, `"abc"`, the 448-bit
    message, 1 000 000 × `"a"` — plus a multi-chunk `update` sequence that must
    equal the one-shot digest and a length sweep across the boundaries.

  - `LSPProvisioningManifest.swift` — the pinned, static description of
    everything the app is allowed to download, and the whole reason a tenth
    language server is one record rather than a feature. `LSPComponent` is a
    version plus a list of `LSPArtifact`s (url, sha256, `byteCount`,
    `unpackedByteCount`, format, `stripComponents`, destination subpath, optional
    architecture); `LSPDownloadableServer` is a closed enum saying which
    components a server needs and where its entry point sits inside them.
    **Nothing is discovered at runtime.** No registry query, no `dist-tags`, no
    "latest": every URL, byte count and digest was resolved by hand and changes
    only by shipping a new app version. That is the point — a checksum fetched
    from the same place as the bytes would verify nothing — and it is also why
    `swift test` needs no network: the data under test is in the file.
    `installationOrder(for:)` lives here rather than in the engine because it is
    a property of the *data*: the manifest is what knows that
    `typescript-language-server` cannot run without `node`. Depth-first with a
    visited set, so a hand-edited cycle terminates instead of hanging.
    `LSPArchiveFormat` is an enum rather than a `Bool` so a second format is a
    compile error at every call site; `LSPHostArchitecture` is the slice the app
    is *running as* (see the limits).
    `serverDescription(manifest:layout:)` is the bridge to 2a: it composes the
    `LSPServerDescription` an installed server becomes — node as the executable,
    the server's entry `.mjs`/`.js` plus `--stdio` as arguments, D11's
    `tsserver.fallbackPath` as `initializationOptions` for the TypeScript one
    (`fallbackPath` rather than `path` so a project's own `node_modules/typescript`
    still wins — see D11). Pure path
    math that checks nothing on disk, so it is testable without a file system;
    `nil` for a manifest that does not describe the server, which keeps malformed
    data a *missing* server (tree-sitter, silently) rather than a trap.
    `LSPProvisioningManifestTests` pins the data the way `DependencyPinTests`
    pins `Package.resolved`: absolute HTTPS URLs on allowed hosts only, 64
    lowercase hex per checksum, positive sizes, `node` covering both
    architectures and the npm artifacts none, every `requires` id and every
    server's components resolving inside the manifest, unique ids and
    destinations, and the served-language sets disjoint and never containing
    `.swift`.

  - `LSPInstallLayout.swift` — where every provisioned file goes (D12/D13), as
    pure path math over a base `URL`. **No file system access, on purpose**:
    nothing here stats, reads, creates or deletes, so a method answering a `URL`
    makes no claim that anything is there, and the engine's tests reason about
    paths against a `StubFileTree` while the app points the same math at
    Application Support.
    Two properties of the shape carry the design. **Version in the path** makes
    an upgrade a fresh directory beside the old one rather than an in-place
    mutation, so a failed upgrade cannot damage a working install — and is why
    `state(of:)` can be a directory listing rather than a database. **Staging
    under the same base** makes the final `move` a rename within one volume; a
    staging directory in `/tmp` would be a cross-device copy with no atomicity to
    offer.
    `base` is standardised and re-spelled as a directory URL so two spellings of
    one root compare equal — the layout is a value the model compares.
    `directoryName` ("LanguageServers") is spelled here and nowhere else, so the
    de-provisioning instructions in `README.md` point at the one place that
    defines it. The staging directory begins with a dot so it can never collide
    with a component id, and `stagingDirectory(…, token:)` takes a per-attempt
    token so a retry cannot adopt a half-written tree a previous attempt left —
    *within one run*. The counter restarts at zero every launch, so the first
    attempt of a run recomputes the path a crashed attempt of the previous run
    may still occupy; `ensureDirectory` would succeed on it and adopt it. The
    engine therefore `discard`s the staging path before it builds there, which is
    what makes the empty tree an established fact rather than an inference from
    the best-effort sweep having worked.
    `contains(_:)` is the containment predicate behind every deletion, and it
    counts the root itself — it answers "inside", and the sweep reads that
    directory. The engine narrows it to `mayDelete(_:)`, which additionally
    refuses the root: every path it deletes is built from a component id or read
    out of a listing, and one that resolved back to the root (a hand-edited
    manifest with `..` in an id, a `.staging` entry that walks out) would take
    every provisioned server with it in a single `removeItem`.

  - `LSPInstallEngine.swift` — the whole of D12–D14: the two seams, the typed
    `LSPInstallError`, `state(of:)`, `install(_:)`, `remove(_:)` and
    `sweepStaging()`.
    **State is the file system.** No database, no receipt file, no cache to get
    out of step with the disk — `state(of:)` is a directory listing plus the
    in-flight table, so deleting the install root de-provisions completely with
    nothing left believing otherwise. `state(of:)` answers `installed` for *any*
    version on disk (a tree stranded by a pin bump is real disk that must remain
    removable); `isInstalled(_:)` is the stricter question — the **pinned**
    version — and is the only one that makes a server servable, because every
    path `serverDescription` composes names that version.
    **The install sequence is D13 in order**: stage → download → **verify** →
    unpack → one `move` onto the version directory → and only then delete what it
    replaced. Verification is before the unpack always: the alternative is
    writing code of unknown provenance into a directory and deleting it
    afterwards, which is a different promise. Every failure between the first
    line and the `move` drops the staging tree and rethrows, so "the previous
    install is exactly as it was" needs no rollback to be true. The old version's
    deletion is best-effort and *after* the rename — failing an install because a
    stale directory could not be removed would turn a successful upgrade into a
    reported failure over some wasted disk.
    **Coalescing is synchronous.** Two installs of one component (the banner and
    a Settings row, or TypeScript and Python both wanting `node`) must produce
    one download and both callers must see the same outcome, so the claim is made
    between the check and the store with no suspension point in between. The
    slot is released from inside the task body and only if it is still that
    attempt's — `LSPWorkspace.flush`'s id discipline, for its reason.
    **A checksum mismatch is terminal for the attempt**: no retry loop, because a
    mirror or an intercepting proxy serving something else will serve it again,
    and the one thing this layer must never do is install code it could not
    verify.
    `@MainActor` like every other model here, because the in-flight table is read
    synchronously by the surfaces in the turn they are drawn; the expensive parts
    all happen inside `await`s off the main actor, so nothing holds it while
    53 MB moves. The download and the unpack are `nonisolated` seams; the digest
    is not a seam and so gets the same treatment explicitly, as a `nonisolated
    static` `async` helper — a plain call to `SHA256.hexadecimalDigest(of:)` from
    `perform(_:)` would hash all 53 MB of the Node tarball on the main thread,
    which measures about a fifth of a second of frozen editor on Apple silicon
    and more on Intel, once per artifact. A `nonisolated async` function does not
    inherit its caller's executor, so only the comparison comes back.
    Deletion is the one expensive thing that *does* run on the main actor, and
    deliberately: `FileServicing` is not `Sendable`, and the whole layer (plus
    `StubFileTree`) is built around it being touched from the main actor only.
    The cost is bounded by user-initiated removals and the launch sweep, and is
    recorded as a known limit below rather than paid for with a threading
    contract this layer cannot safely change on its own.
    **A reader of the project, a writer only of its own
    directory** — it takes no `autosave.suspend()`/`localChanges.beginRevert()`
    gate and is not gated by one, the rule the symbol index and the rest of the
    LSP layer already follow.
    `sweepStaging()` runs once at launch, before anything can be installed, so
    what it finds is by definition unreachable garbage; it never throws, because
    a launch must not fail over a directory nobody will look in.
    `remove(_:)` reports `removeFailed` rather than `fileSystemFailed`, purely so
    the sentence a Settings row shows describes what the user asked for: a
    removal that reads "could not install" names a different failure than the one
    that happened.
    `LSPInstallEngineTests` drives all of it through `ScriptedInstallSeams`: a
    no-op reinstall performing zero downloads, a mismatch leaving nothing behind
    and not re-downloading, injected failures at download/checksum/unpack/move
    each leaving the previous install byte-for-byte, a version bump installing
    beside and then removing the old one, two concurrent installs performing one
    download, `installing` observed between them, the sweep removing leftovers
    and nothing else, and a runtime failure aborting the server install.

  - `LSPProvisioning.swift` — consent as a value (`LSPServerConsent`), the two
    view-facing values (`LSPConsentPrompt`, `LSPServerRow`), and
    `LSPProvisioningModel`: the one thing that knows which servers exist, what
    state each is in, and what the registry should therefore look like now.
    **Why a model and not two views doing arithmetic.** The banner and the
    Settings surface ask overlapping questions and both can *answer* them, so two
    independent readers of the engine would drift the moment one acted — a banner
    accepting while a row still says "not installed" — and would each need their
    own opinion about when to push a registry. Everything decision-shaped is
    therefore here and the views are `rows`, `consentPrompt(forOpening:)` and four
    verbs.
    **The registry is the output.** It starts as the base one (sourcekit-lsp,
    which this layer neither provisions nor can interfere with) and gains an
    entry per *installed* server; the base entries stay first, so
    `LSPServerRegistry`'s first-registration-wins rule keeps a hand-registered
    override winning. Every change is pushed through `onRegistryChange`, which
    the app wires to `LSPWorkspace.updateRegistry(_:)` — and it is **awaited**,
    because `remove(_:)` publishes a registry without the server *before*
    deleting its files: the push is what shuts the process down (D16), and
    deleting an executable out from under a live process is exactly the orphan
    the release check greps for. The "publish only when different" guard is not
    an optimisation — relying on `updateRegistry`'s own early return would make a
    later refactor kill running servers on a timer.
    `consentPrompt(forOpening:)` is a pure rule over three facts (a downloadable
    language, consent `unasked`, nothing installed or installing), which is how a
    banner with no dismiss button nonetheless never appears twice. It reads those
    facts off the published `rows` rather than re-deriving them from the engine,
    and that is load-bearing rather than tidy: the banner calls it from its
    `body`, so an engine-backed version would run five synchronous directory
    listings on the main thread on every editor re-render — every keystroke, for
    as long as the question stayed open. `rows` is recomputed at exactly the
    moments the answer can change, so it is both cheaper and the same answer the
    Settings surface is showing.
    `prepareForOpening(_:)` is the silent half of D15: an *already accepted*
    server whose files are missing installs on first use without asking again —
    **once per app run**. A failed attempt leaves the server `absent`, so the
    method's guard consults `failures` as well as the state: without it, every
    switch back to a `.ts` tab would restart the same ~52 MB download (the
    machine is offline, or a proxy is serving something that fails the digest,
    and neither changes because a tab did) *and* wipe the row's
    `failureMessage`, which `install(_:)` clears before each attempt — so the one
    place D15 reports the failure would be erased by the very tab switch that
    re-triggered it. The Settings row's Retry stays unconditional, and so does
    the next launch: the record lives in the model, not on disk.
    The model keeps its own per-*server* attempt table beside the engine's
    per-*component* one, so a row reads "installing…" from the moment the user
    says yes — including while it waits on a shared `node` another server is
    already fetching — while a server nobody asked about does **not** inherit
    `installing` from that shared download. Each attempt carries an id and
    releases its own slot *from inside the task body*, the engine's rule for the
    engine's reason: a finished task left sitting in the slot until the awaiting
    owner's continuation ran would be adopted by a Retry landing in that window,
    which would return immediately and install nothing while the row updated as
    though it had.
    `install(_:)` records `accepted` first (installing *is* consent) and absorbs
    every failure into the row's `failureMessage`, which is the entire failure
    surface of this feature. `remove(_:)` sets consent to `declined` — the only
    answer that describes what just happened, since leaving it `accepted` would
    silently re-download on the next `.ts` file and `unasked` would re-prompt —
    and drops the shared runtime only when no other server has *any* files on disk
    **or an attempt this model is holding**, so a server stranded by a pin bump is
    not turned into a full re-download and neither is one whose download the user
    has just accepted. A deletion that *fails* becomes the row's `failureMessage`
    like any other failure, and it has to: the files are still there, so the very
    next `publishRegistry()` re-registers the server and restarts the process the
    push just stopped — a Remove that visibly undoes itself with nothing anywhere
    saying why.
    **The decline is recorded between the two deletions**, and that placement is a
    rule rather than an ordering detail: consent describes the *server*, so it
    follows the fate of the server's own component and of nothing else. A failed
    `engine.remove(serverComponentID)` records **no** consent — that server is
    installed, registered and answering requests, which is the one state
    `declined` may not describe. But once that call returns, the server *is* gone
    (`makeRegistry()` will not re-register it, the row reads `.absent`), so a
    shared runtime that then refuses to delete must not roll the answer back with
    it: `accepted` describing a server with no files has the next launch's
    `prepareForOpening` silently re-download the ~52 MB the user just removed,
    while this run's row offers a button labelled Retry that installs. The runtime
    failure is still the row's message; it is just not the server's answer.
    `testAFailedRuntimeRemovalIsReportedButStillDeclinesTheServerItRemoved` pins
    both halves, through a rebuilt model over the same disk and defaults.
    A removal in flight is a state of its own. The push is awaited (it is what
    stops the process), so the model sits inside `onRegistryChange` for as long as
    the shutdown budget allows, and the row publishes `isRemoving` for that whole
    window — `canRemove` is false and the Settings row reads "Removing…". The
    model does not rely on the view for that: `remove(_:)` returns immediately on
    re-entry. Without both, a second Remove clicked during the shutdown finds the
    registry already published, so *its* `publishRegistry()` returns without ever
    suspending and it walks straight into the deletion, pulling the executable out
    from under the session the first call is still stopping — exactly the orphan
    the push-then-delete ordering exists to prevent.
    **An install of the same server is the other thing `remove(_:)` refuses**, and
    that one is reachable rather than theoretical. The stranded runtime is the one
    state that puts Install and Remove on a single row at the same time (server
    component absent, `node` on disk and reclaimable by this row), so a Remove
    clicked off a snapshot taken a frame before Retry claimed the attempt arrives
    with an install in flight. `engine.remove(serverComponentID)` then no-ops —
    the attempt has committed nothing yet, it is all still staging — and the
    removal walks on to the shared runtime, which
    `runtimeIsNeeded(byAnythingOtherThan:)` reports as needed by nothing, because
    it only ever asks about the *other* servers. The install commits its artifact
    onto a deleted `node` a moment later: a server the row reads as absent,
    servable by nothing, under a `declined` it never asked for, with the download
    spent. Or, if the runtime was itself still staging, nothing is deleted at all
    and both components commit — a fully servable, registered server under
    `declined`. `attempts[server] == nil` is the guard
    (`testARemoveArrivingWhileTheSameServerInstallsDoesNothing`), and `canInstall`
    gains `!isRemoving` for the view half: `state` cannot express it, because a
    removal that starts from the stranded state reads `.absent` throughout, so the
    row would otherwise offer Install beside its own "Removing…"
    (`testARowBeingRemovedOffersNeitherButton`). `install(_:)` carries the mirror
    guard on `removals`; that one is a net over an unreachable state in
    `mayDelete(_:)`'s mould rather than a fix — `remove(_:)` suspends only inside
    the shutdown push, which precedes every deletion and so only ever happens for
    an installed server, where an install finds everything on disk and does
    nothing — and it is written down because that reachability is a fact about
    where the one `await` currently sits.
    `hasFilesOnDisk` — what Remove would reclaim — is the server's component at
    any version (the stranded-pin case) **plus the shared runtime when this row is
    what stranded it**. A server is two components installed in manifest order and
    committed by separate renames, so a download that dies on the 4 MB tarball
    after the 52 MB one landed leaves ~110 MB unpacked under a row that reads "not
    installed"; deriving this from the server component alone left `canRemove`
    false on every row in that state, with the Finder as the only way out. The
    runtime is deliberately *kept* rather than swept — the retry then costs 4 MB
    and not 56 — so this makes it reclaimable, not automatic. The clause is gated
    on the row having been **answered about** (consent is anything but `unasked`)
    and on nothing else needing the runtime (`removeRuntimeIfUnused`'s own rule),
    so the orphan is offered under a row the user has actually acted on rather
    than under an untouched one that merely shares the runtime, and a row never
    offers a Remove that would reclaim nothing. `declined` has to count, and that
    is the second state this clause exists for: the decline is recorded *between*
    the two deletions, so a `removeRuntimeIfUnused` that throws lands on a row that
    is already `declined`, and requiring `accepted` made that state terminal —
    ~110 MB of Node on disk, `canRemove` false on every row, the Finder the only
    way out, under a row whose own message says the removal failed. Both halves
    are read off the disk and the defaults, so it survives the relaunch too
    (`testTheRuntimeAFailedRemovalStrandedStaysReclaimable`).
    The row also publishes `failureWasRemoval` beside the message, for one reason:
    that same state is `.absent`, so `canInstall` is true, and the install button
    is labelled "Retry" after a failure. "Retry" beside a sentence beginning
    "Could not remove" reads as retrying the removal while actually starting a
    fresh ~52 MB download of the server the user just removed, so a removal
    failure labels it "Install"
    (`testTheInstallButtonDoesNotOfferToRetryAFailedRemoval`).
    `LSPProvisioningModelTests` pins the rules over the task-3 fakes, including
    the ones about what must *not* change: installing pyright leaves a TypeScript
    answer byte-identical, installing the TypeScript server leaves a Python one,
    and neither touches Swift.

  - `SettingsStore.swift` (modified) — persists consent per server id as one
    dictionary of `serverID → LSPServerConsent.rawValue` under
    `settings.lspServerConsent`, read leniently: an unknown stored value reads
    back as `unasked`, and `unasked` is stored as *absence* rather than as a
    value, so the default and the erased state are the same thing. `private(set)`
    with `setConsent(_:for:)` as the only writer, in the store's existing mould.
    An answer equal to the recorded one writes nothing: the dictionary is
    `@Published` and `ContentView` observes this store, so a no-op consent write
    would re-evaluate the project tree, the tab list and the editor — and
    `install(_:)` records `accepted` on every call, including the
    already-accepted ones the silent half makes on tab opens.
    Full entry in `core-services.md`.

  - `LSPWorkspace.swift` (modified) — gains `updateRegistry(_:)` (D16). Full
    entry in `core-lsp.md`.

### `Pisaka` (app, macOS-gated)

  - `LSPDownloadService.swift` — the real `LSPArtifactDownloading`: one
    `URLSession`, one request, one `Data`. Untested by repository convention, so
    it is kept to the two decisions it actually makes — how the session is
    configured, and what counts as a failure.
    **Nothing is cached, at any layer**: the session is `.ephemeral`, its
    `urlCache` is `nil`, and every request is
    `.reloadIgnoringLocalAndRemoteCacheData`. Three statements of one intent,
    because the alternative is a 53 MB tarball sitting in the user's cache for a
    file already unpacked into its final home — and a second place bytes can come
    from. **No cookies and no credentials**, which an ephemeral session gives by
    construction: every URL is a public tarball and there is nothing that should
    be sent. `waitsForConnectivity` stays off on purpose — it would turn "there
    is no network" into a request that sits silently until the resource timeout,
    where this layer's answer is to fail immediately and leave a Retry button.
    Timeouts are stated (60 s per request, 20 min per resource) and a non-200 or
    non-HTTP response is a `Failure`. Its cases are **bare reason phrases**, not
    `LSPInstallError`s: the engine re-attributes whatever this throws to the
    component it is installing, so a typed install error here would surface as
    two attributions of one failure. That is the shape `ScriptedDownloader`
    already takes, which is what makes the fake a faithful stand-in.

  - `LSPArchiveUnpacker.swift` — the real `LSPArchiveUnpacking`: one
    `/usr/bin/tar -xz --strip-components=<n> -C <dir>`, fed on stdin.
    **A system binary, not a library**: macOS ships bsdtar and it has read gzip'd
    tarballs correctly for longer than this project has existed; linking
    libarchive (or writing an inflater and a tar reader) would add a dependency
    and a license obligation to avoid a subprocess the app already spawns several
    of. Spelled as an absolute path rather than through `/usr/bin/env`, for
    `LSPToolchain.locate`'s reason: a `PATH` entry must not decide which `tar`
    unpacks code that is about to be executed.
    **The bytes go in on stdin**, so the verified bytes and the unpacked bytes
    are the same bytes with no window in between, and there is no temporary file
    to create, hide and delete on every failure path.
    Three streams, three threads, none waiting on another — `GitCLIService`'s
    deadlock rule, which bites harder here than anywhere else in the app because
    the archive is far larger than any pipe buffer. `F_SETNOSIGPIPE` on the write
    descriptor, per descriptor rather than process-wide, exactly as
    `LSPProcessTransport` does: a `tar` that rejects the archive exits with tens
    of megabytes still queued, and the default disposition of `SIGPIPE` kills the
    *app*. A non-zero exit becomes `Failure.extractionFailed` carrying the last
    diagnostic line, trimmed and capped — what ends up in a Settings row should
    be a sentence, not a log.
    **`tar` has ten minutes, and is killed when it misses them.** The download
    seam is bounded on both axes (60 s request, 20 min resource); this half was
    not, which made it the one unbounded operation in an install and the only one
    whose failure had no bottom. The state proves it: `LSPInstallEngine` holds the
    component in `installs` and `LSPProvisioningModel` holds the server in
    `attempts` until this call returns, and *both* of those are what report
    `.installing` — so a continuation that never resumes leaves the row spinning
    with `canInstall` and `canRemove` false and `remove(_:)` refusing on its own
    `attempts[server] == nil` guard. Not a slow install but a dead one, for the
    rest of the app run, with nothing said and no way back but quitting. Ten
    minutes is picked the way the resource timeout was — two orders of magnitude
    above the seconds the largest (53 MB) component really takes, and far below
    the "never" it is actually competing with. Missing it is SIGTERM, a grace
    period, then SIGKILL (`LSPProcessTransport`'s teardown, for its reason: a
    process wedged past the deadline may also ignore a polite signal, and it is
    holding a staging directory that is about to be deleted), and then
    `Failure.timedOut` — which the engine's existing `catch` turns into the same
    discarded staging tree and "not installed + Retry" row as every other failure.
    The deadline is also why stderr moved off the calling thread onto a third
    queue and why the drains are joined with a bounded `DispatchGroup.wait`
    instead of `sync {}`: a thread that must enforce a timeout cannot be parked in
    `readDataToEndOfFile`, and a join that can block forever would reinstate the
    unbounded wait from the other side. Because the timeout path can expire while
    that drain is still running, the collected stderr lives behind a small lock
    rather than in a local — the drains only decorate the outcome the exit status
    already decided, so an unfinished one costs a diagnostic line, not correctness.

  - `LSPConsentBanner.swift` — the one place this app asks to download something
    (D15). A non-modal strip between the breadcrumb and the find bar, shown only
    while `consentPrompt(forOpening:)` answers for the selected tab's language,
    so it holds no state of its own and cannot disagree with the Settings surface
    about whether the question is still open.
    **Two actions and no third way out**: no ✕, no "Later", no Esc. The banner
    disappears when consent stops being `unasked`, which happens only through
    Download or No Thanks — a dismiss would leave the answer `unasked` and bring
    the strip back on the next `.ts` file, which is how a prompt turns into
    something people close without reading. Both answers are reversible from
    Preferences → Language Servers, which is what makes a forced choice fair.
    **Non-modal on purpose**: the file is open, editable and already answering
    from the index; this is an offer to make those answers better, not a
    precondition for working.
    It also carries the silent half of D15 — a `.task` calling
    `prepareForOpening`, so both halves of "what happens when this file is
    opened" live in one place. Download is unawaited: the install runs for
    minutes and the banner must go away the moment the answer is recorded.
    **The body's container is a `VStack(spacing: 0)` and must not be a `Group`.**
    The silent half only ever runs in the state where the banner is *absent*, so
    it lives on a modifier attached to a container with no children — and a
    modifier on a `Group` is applied to each of its members individually, so an
    empty one applies it to nothing and the `.task` is never installed at all.
    That failure is silent and total: the visible half keeps working, because its
    branch is non-empty exactly when there is something to show, while the half
    that matters here never runs once. An empty `VStack` contributes no height, so
    the "costs the editor no layout" property the shape exists for is unchanged.
    **Both halves are gated on a project folder being open**, and the `.task` id
    is `(language, hasProjectRoot)` rather than the language alone so that
    opening a folder re-runs them. `LSPWorkspace.prepare` and `canServe` both
    open with `guard let root = currentRoot`, and the root is set by opening a
    *folder* — a `.ts` file opened on its own with ⌘O leaves it `nil`. Offering
    52 MB there would spend the one-shot, permanent consent in the one state
    where accepting demonstrably changes nothing.
    `size(_:)` formats through `ByteCountFormatter`, so "52.2 MB" here means what
    it means in the Finder.
    **It asks the Go question too, and never both at once.** A second branch
    renders `LSPGoplsProvisioningModel.consentPrompt(forOpening:)` in the same
    strip, with the same two actions and the same absence of a dismiss, and the
    `.task` calls both models' `prepareForOpening` in the same branch order. The
    copy is what differs, because what happens differs: a hammer rather than a
    download arrow, no size at all, and a sentence naming the user's own `go` —
    accepting builds gopls from source with the toolchain at that path, and
    Pisaka downloads nothing (D20). **That copy claims only what the install
    keeps**: nothing is *installed* outside the app's own folder, and the build
    "runs as your own `go install` would, using and adding to your Go module and
    build caches". Only `GOBIN` is redirected, so the intermediates are the user's
    (`GOMODCACHE`/`GOCACHE`, plus whatever `GOTOOLCHAIN=auto` fetches into them) —
    both recorded known limits in `core-lsp.md`, and the reason an earlier
    "nothing outside its own folder is changed" was too strong a sentence to show
    above a button that grants consent. The download branch is checked first and is
    stated to win; the two contributors serve disjoint languages and cannot
    collide today, but a strip asking two questions in one row would be a worse
    thing to discover than an arbitrary order. `strip` is generic over its
    content so both rows share the bottom rule.

  - `LSPServerSettingsView.swift` — Preferences → Language Servers, the whole
    management surface: one row per downloadable server showing the state the
    model derived (not installed · size / not installed · declined / Installing…
    / Removing… / Installed · version) and the actions that apply to it. The
    removal state is checked ahead of the install state, because a removal keeps
    reading `installed` right up until the files go — the wait in between is a
    live session being stopped (D16) — and a row that says "Installed" while its
    button has just vanished is the one thing that window must not look like. No
    progress bar (the
    engine reports no progress, because the download seam answers whole bytes —
    D14), no install log, no version picker (the manifest is pinned data), and no
    way to add a server that is not in it. This is where a "no" is turned around,
    which is what makes the banner's forced choice reasonable, and the only place
    an install failure is ever surfaced: a sentence and a Retry, never an alert.
    "Retry" is the label only after a failed *install* — `row.failureWasRemoval`
    puts "Install" back on a row whose message is about a removal, because the
    action there is a fresh download rather than a second attempt at what the
    message describes.
    A thin view in the `GeneralSettingsView` mould — every rule (which actions
    apply, what the state is, what it costs) is a property of `LSPServerRow` and
    is unit-tested in Core.
    **The Go row is last, under the same rules from a different model.** It
    renders `LSPGoServerRow` — D19's states plus the `pending` one the lifecycle
    starts in, drawn as "Looking for a Go toolchain…" rather than guessed at —
    with Install/Retry gated on `canInstall` and Remove on `canRemove`, neither
    rule spelled in the view. It comes after the downloadable rows because those
    are a fixed, stated list (`LSPDownloadableServer.allCases`) and appending
    keeps that order visible rather than interleaving a row that obeys different
    rules. Two of the tab's own sentences changed with it, both made untrue by a
    server that is *built* rather than fetched: the header now says "download or
    build", and the install-root footer says **anything Pisaka installs** lives
    there — a gopls found in `~/go/bin` is used from where it is and is no more
    affected by deleting that directory than by the Remove button that does not
    appear for it. A third sentence is new and is gopls's whole licence surface;
    see `LSPInstalledLicenses.swift` below for why it is a sentence here rather
    than a document there.

  - `LSPInstalledLicenses.swift` — the license texts of whatever is *installed*,
    read from the installed tree. **Why these are not in `Resources/Licenses/`**:
    everything there ships inside the app and is pinned by
    `LicenseCoverageTests`; these five packages ship inside nothing — they arrive
    later, only if the user asks, and are gone when the user removes them.
    Checking their texts into the bundle would acknowledge software the app may
    never have on disk and would go stale against a pin bump the moment one file
    was updated and the other forgotten. Reading the verbatim text out of the
    tree that was actually installed makes the notice and the code it covers the
    same bytes.
    One `LicenseDocument` per *component*, matching the repository's existing
    package-granular convention: a component carrying a second package
    (`typescript` beside its server, `fsevents` beside pyright) has that
    package's verbatim text appended below a line marking where the first ends —
    the shape `Resources/Licenses/tree-sitter.txt` and `libgit2.txt` already use.
    The notice's `revision` field is `sha256:<digest>` of the artifact for the
    slice this app is running as, spelled with its algorithm because the header
    renders that field as "Revision" and a bare 64 hex characters would read as a
    git object id. "Installed" here is `isInstalled(_:)` — the pinned version —
    since acknowledging software the app is not running would be noise in the one
    screen that must be exact. An unreadable text is skipped rather than
    substituted; it cannot happen for an install this app performed, so the ways
    there are a hand-edited install root and a `licenseFileSubpaths` entry a pin
    bump left stale. Because of that skip, the notice's `file` field names the
    first subpath **actually read**, not `licenseFileSubpaths.first`: the two
    differ exactly when the first file is missing, and taking the name from the
    list would caption the second file's text with the first file's path — which
    the separator line ("everything above this line is the verbatim text of the
    file named at the top of this entry") would then restate, compounding the
    mislabel instead of containing it.
    **gopls is deliberately not here.** `go install` writes one binary and
    nothing else, so there is no licence file in the installed tree to read —
    and nothing for `licenses.json` to cover either, this app bundling no gopls
    bytes at all. The substitute is one sentence in the Language Servers tab
    naming the origin and the BSD-3-Clause licence, built from `LSPGopls.origin`
    / `licenseSPDX` so the fact lives in Core beside the pin. That is a decision
    rather than an omission, which is why it is written down in both places.

  - `PisakaApp.swift` (modified) — composes the layer exactly once in `init`:
    the install root (`~/Library/Application Support/Pisaka/LanguageServers` —
    Application Support rather than Caches, because a purged cache would silently
    un-provision every accepted language and re-download 56 MB without asking),
    the host architecture from `#if arch(arm64)`, the engine over the two
    concrete seams, the model over the engine and the shared `SettingsStore`, and
    `onRegistryChange` pushing into `lspWorkspace.updateRegistry(_:)`. The
    workspace is captured directly rather than through `self`, since the closure
    must outlive a half-built value. `makeProvisioning(settings:)` is a factory
    rather than two inline expressions so the default-constructed `ContentView`
    (previews) builds the same stack and the install root is spelled once.
    At launch, under the same one-shot gate as the session restore:
    `sweepStaging()` synchronously first (it is only safe *because* nothing can
    be installing yet), then an unawaited `refresh()` — the file system is the
    state, so "restore the registry" is a directory listing and a language
    answers from tree-sitter for the moment it takes, exactly as it does when no
    server exists. Full entry in `app-shell.md`.
    **The gopls pair is composed beside it, over the *same* engine.**
    `makeGopls(engine:settings:)` takes the engine `makeProvisioning` built
    rather than constructing a second one: the install root is one directory and
    `sweepStaging()` sweeps all of it, so two layouts over one path is how a
    Remove ends up looking where nothing was written. Discovery is kicked off
    here, unawaited (`LSPToolchain.prewarm()`'s position), so a machine with no
    `go` spends its login-shell search entirely off the launch path. The registry
    merge is **two** `@MainActor` closures rather than one shared function —
    each takes its own contributor's *new* value as a parameter and reads the
    other's published one, which is what makes the push see the change being made
    rather than the state before it. The service is held by `PisakaApp` (not only
    by the model) because the terminate observer calls its `terminateNow()`
    beside `lspWorkspace`'s: a quit mid-build must leave no `go` child, and the
    teardown is permanent as well as immediate, so a `.go` tab opened after the
    observer cannot start another build.

  - `ContentView.swift` (modified) — hosts `LSPConsentBanner` in the editor zone
    between the path bar and the find bar, keyed on
    `SyntaxLanguage(forFileName:)` of the selected tab, and hands it **both**
    contributors. Neither is observed here, for the same reason: the banner
    observes them itself, and a `ContentView` that did would redraw the whole
    window on every install state change. Full entry in `app-window.md`.

  - `SettingsView.swift` / `AcknowledgementsView.swift` (modified) — Preferences
    gains a third tab (which now also threads the gopls model through to the
    Language Servers pane, and only there — gopls ships no licence file into its
    install, so Acknowledgements has nothing of it to show), and Acknowledgements
    gains a "Language Servers" section
    that exists only while something is installed. The section is re-read on a
    `.task(id: provisioning.rows)`, so an install completing, a removal finishing
    and a relaunch's `refresh()` all land there for free; a removal that deletes
    the selected entry falls back to the first bundled one. Full entries in
    `app-shell.md`.

## Decisions

**D11 — How `typescript-language-server` finds `typescript`.** As a second
artifact of the same component, unpacked beside it:
`.../typescript-language-server/5.3.0/node_modules/{typescript-language-server,typescript}`.
Node's own resolution finds it by walking up from `cli.mjs`, and the registry
entry additionally passes
`initializationOptions = {"tsserver": {"fallbackPath": "<…>/node_modules/typescript/lib/tsserver.js"}}`
so the lookup never depends on the walk.

**`fallbackPath`, not `path`, and the distinction is the whole decision.**
`typescript-language-server` resolves in a fixed order: `tsserver.path`, then the
workspace's own `node_modules/typescript/lib`, then `tsserver.fallbackPath`, then
whatever `require.resolve('typescript')` finds from its own install. Naming the
pinned copy under `path` would put it *ahead* of the workspace, so a repository
pinned to TypeScript 4.x — or to a nightly — would be analysed by 5.9.3 with no
way to say otherwise. Under `fallbackPath` the pinned copy is what a project
without one gets, and a project with its own `node_modules/typescript` still
wins, which is the behavior people expect from every other editor.

One component rather than two, because the
pair is only ever installed and removed together. `typescript` is pinned at
**5.9.3**, not the `latest` 7.x: 7.0 is the native rewrite and no longer ships
the `lib/tsserver.js` this server drives.

**D12 — Component = version directory of verified artifacts; state is the file
system.** `<Application Support>/Pisaka/LanguageServers/<component>/<version>/…`.
Installed/absent is a directory listing; installing is the engine's in-flight
table. No database, no receipt file, nothing persisted about what was registered
last time — which is what makes "delete that directory" a complete
de-provisioning and a relaunch's `refresh()` a directory walk.

**D13 — Atomicity is one rename.** Download → SHA-256 → unpack, all into
`…/LanguageServers/.staging/<component>-<version>-<n>/`, then a single `move`
onto the version directory; the previous version is deleted only afterwards. Any
failure removes the staging tree and leaves the old install (or nothing) exactly
as it was. Staging lives under the same base so the rename is within one volume.
Leftover staging from a crash is swept at launch, before anything can install.

**D14 — The seams carry bytes, not files.** `LSPArtifactDownloading` answers
`Data` for a URL; `LSPArchiveUnpacking` takes that `Data`, a destination and a
strip depth. Core never reads or writes archive bytes, so `swift test` needs
neither network nor `tar`. Handing back a file URL instead would make Core
responsible for a temporary file it would have to hash, unpack *and* delete on
four different failure paths; the price is the peak resident size of the largest
artifact (~53 MB), recorded as a known limit.

**D15 — Consent is per server, sized, and sticky.** `SettingsStore` persists
`unasked`/`accepted`/`declined` per server id. Accepting installs the server
*and* its missing runtime; declining keeps the language on tree-sitter across
launches. The prompt is a non-modal banner above the editor with two actions and
no dismiss — "asked once" means the answer is one of the two. The size shown is
what is still *missing*, so the second server offers ~4 MB rather than ~56. An
accepted-but-absent server installs on first use without asking again; a failed
install is a sentence in a Settings row and a Retry button, and raises nothing
anywhere else.

**D16 — Registration is dynamic, and removal terminates.** `LSPWorkspace` gains
`updateRegistry(_:)`: it swaps the registry, and shuts down every session whose
description vanished *or changed* (id, launch, arguments or initialization
options), `didClose`ing its documents first, dropping its transport and clearing
its D7 failure/unavailable bookkeeping so a re-added server starts with a fresh
budget. `canServe` therefore flips both ways without a restart, and
`RoutingIntelligenceProvider` is untouched. A removal publishes the new registry
*before* deleting files, so the process is gone before its executable is.

## The pinned manifest

One shared Node runtime plus one component per server, and one standalone binary
that needs no runtime at all. Sources are official only: `nodejs.org/dist`
(checksums verified against the release's own `SHASUMS256.txt`),
`registry.npmjs.org` tarball URLs, and the `rust-lang/rust-analyzer` GitHub
release assets.

| component | version | license | artifacts (sha256 · download bytes) |
|---|---|---|---|
| `node` | 24.19.0 | MIT | `node-v24.19.0-darwin-arm64.tar.gz` `8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d` · 52 234 372<br>`node-v24.19.0-darwin-x64.tar.gz` `d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316` · 53 439 583 |
| `typescript-language-server` | 5.3.0 | Apache-2.0 | `typescript-language-server-5.3.0.tgz` `398cacc17fff2108652e7b4050e3182008d17063246b3fea7dcf5fae2ce1560e` · 501 633<br>`typescript-5.9.3.tgz` `10e108c9cf7d5f2879053dff18515fb405abf2ccef63eaaf017d9c571687a1d3` · 4 377 468 |
| `pyright` | 1.1.411 | MIT | `pyright-1.1.411.tgz` `bd5c488fc20fa237a944279bf32cae2f986cf10d5d5d9e8705819859daeb2f4a` · 4 139 958<br>`fsevents-2.3.3.tgz` `c77e7a5d5ff31dd7acea7c44d4a0455e0528cdacbd24a8cb6c82b66d239b587e` · 22 808 |
| `rust-analyzer` | 2026-08-03 | Apache-2.0 OR MIT | `rust-analyzer-aarch64-apple-darwin.gz` `bba6cd8209643cd781f3ee5474fa232d3ee1b77a57f2e77982806e3c80a65207` · 13 873 448<br>`rust-analyzer-x86_64-apple-darwin.gz` `8966f9429085c243817b9d13afa76e98920668c07a9b432901daaf047397c6cb` · 14 576 027 |

`fsevents` is macOS-only, optional and prebuilt; it costs 22 KB and avoids the
resolution warning its absence produces. There is nothing else transitive —
which is why this whole layer needs no `npm`, no lockfile and no dependency
solver.

`rust-analyzer` is the odd row, in four ways that are each a decision rather than
an accident:

- It is the only `.gzip` artifact — a bare `.gz` of one Mach-O executable, so
  `stripComponents` is 0, the file's name lives in the format's payload
  (`.gzip(fileName: "rust-analyzer")`, D22) because the archive carries none, and
  the engine verifies the executable bit before it commits.
- It **requires nothing**. Every other component here is Node or a Node argument;
  this one is run by the kernel, so `installationOrder` for it is the single
  component and accepting Rust downloads ~13 MB rather than ~66.
- Its `licenseFileSubpaths` is **empty**, and that is D24: the archive holds one
  binary and no notice, so `LSPInstalledLicenses` has nothing to read and
  `licenses.json` covers nothing (this app bundles none of its bytes). The
  substitute is one sentence in the Settings row naming the origin and the
  `Apache-2.0 OR MIT` dual license. `licenseSPDX` uses `OR` for the first time —
  the other expressions here use `AND`, which says the tree is under both at once;
  `OR` says upstream offers a choice.
- Its **version is a date**, because that is what upstream ships. It sorts
  correctly lexicographically, which is the one property `state(of:)` asks of a
  version string, and it is the reason the procedure below gets re-run more often
  for this component than for any other.

It also has **no `LSPDownloadableServer` case** (D21): what Rust reuses from this
layer is the pinned component and the engine that installs it, not
`LSPProvisioningModel` — a 2b row cannot say "no Rust toolchain", and Rust's
lifecycle therefore lives in its own Core model beside gopls's.

### Updating a pin, by hand

The manifest is data in Core, so a version bump is a source change plus the
checksums below — never a runtime lookup. Nothing in `project.yml`,
`Package.resolved` or `licenses.json` is involved.

**`LSPComponent.version` is the install key, so it must move whenever *any* of
that component's artifacts does.** D12 makes the version directory the whole of
the state: `isInstalled(_:)` is "does `<component>/<version>/` exist", and
`install(_:)` returns immediately when it does, without looking at a single
digest. A component bundles independently-versioned artifacts — `typescript`
5.9.3 rides inside `typescript-language-server` 5.3.0, `fsevents` inside
`pyright` — and bumping only an inner one leaves every existing install
permanently stale: the same directory name still exists, so nothing re-downloads,
and the pin the source now states is one no machine that already installed will
ever run. Nothing catches this — the manifest tests check the artifact list
against itself, and a stale tree is byte-for-byte a valid install. When an inner
artifact moves and the outer package has not, bump the component's `version`
anyway (the outer package's version with a suffix is enough); the cost is one
re-download of a component that was already correct, against a silent
never-updates otherwise.

Node (both architectures come from one signed checksum file):

```sh
V=24.19.0
curl -fsSL "https://nodejs.org/dist/v$V/SHASUMS256.txt" \
  | grep -E "darwin-(arm64|x64)\.tar\.gz$"
# → the two sha256 values, verbatim, in the form LSPArtifact.sha256 pins.

for A in arm64 x64; do
  curl -fsSLI "https://nodejs.org/dist/v$V/node-v$V-darwin-$A.tar.gz" \
    | awk 'tolower($1) == "content-length:" { print $2 }'
done
# → byteCount for each artifact.
```

An npm tarball (the registry publishes no checksum file, so the digest is taken
from the bytes themselves):

```sh
P=typescript-language-server; V=5.3.0
URL="https://registry.npmjs.org/$P/-/$P-$V.tgz"
curl -fsSL "$URL" | shasum -a 256          # → sha256
curl -fsSL "$URL" | wc -c                  # → byteCount
```

`unpackedByteCount` is measured once and rounded. **Nothing reads it at runtime**
— no surface shows a disk figure and nothing checks for free space before an
unpack (a full volume surfaces as `unpackFailed`, which discards the staging tree
and leaves the previous install alone, so the outcome is already right). It is
recorded because whoever bumps a pin has to know what they are shipping, and
`LSPProvisioningManifestTests` keeps it from drifting into nonsense:

```sh
D=$(mktemp -d); curl -fsSL "$URL" | tar -xz --strip-components=1 -C "$D"
du -sk "$D" | awk '{ print $1 * 1024 }'    # → unpackedByteCount, then round
rm -rf "$D"
```

A GitHub release asset — rust-analyzer, and the reason this section has a third
recipe. It is also the one that is run most often, because the pin is a *date*
and upstream cuts a release every week; the numbers below are the whole of a
bump, since there is no license path and no entry point to re-check inside an
archive of one file.

```sh
V=2026-08-03
for A in aarch64 x86_64; do
  URL="https://github.com/rust-lang/rust-analyzer/releases/download/$V/rust-analyzer-$A-apple-darwin.gz"
  curl -fsSL "$URL" -o /tmp/ra.gz
  shasum -a 256 /tmp/ra.gz                 # → sha256
  wc -c < /tmp/ra.gz                       # → byteCount
  gunzip -c /tmp/ra.gz > /tmp/ra           # the whole unpack: one file, no layout
  wc -c < /tmp/ra                          # → unpackedByteCount (exact, not rounded)
  file /tmp/ra                             # → confirm the slice: Mach-O arm64 / x86_64
  rm -f /tmp/ra.gz /tmp/ra
done
```

`curl -o` rather than a pipe, because the URL redirects to
`objects.githubusercontent.com` and both the digest and the byte count must be
taken from the bytes that actually arrive. `unpackedByteCount` is exact here
rather than rounded: it is one file, so `du` has nothing to round up to a block
size that `wc -c` does not already say precisely.

Two things worth confirming by hand on a bump, neither of which any test can see.
`file` must report the architecture the artifact's `architecture:` claims — the
two URLs differ by one word and a swap installs a binary that cannot execute on
either Mac. And the binary is `adhoc, linker-signed` as published, so it launches
on Apple silicon with no signing step of ours; bytes written by `URLSession` carry
no `com.apple.quarantine`, exactly as the Node binaries this layer already
installs do not. If a future release ships unsigned, the executable gate would
still pass and the process would die at `exec` — which surfaces as D7's silent
fallback to tree-sitter, so it is worth a `/tmp/ra --version` before shipping the
pin.

After a bump, re-check the two things that are not mechanical: that the license
subpaths in `licenseFileSubpaths` still exist inside the new tarball (the
Acknowledgements section silently drops a component whose texts it cannot read),
and that `executableSubpath` still names the entry point the package ships.

The first of those is more than a path check, and it is the step most likely to
be skipped. **A package's own LICENSE is not automatically the whole
obligation** — the repository's rule for the bundled texts in
`Resources/Licenses/` (libgit2's LGPL `deps/xdiff`, tree-sitter's ICU-licensed
`lib/src/unicode`) applies here for the same reason. Two of these components
already carry a second notice found exactly this way:

```sh
tar tzf "$P-$V.tgz" | grep -iE 'licen|copying|notice|third.?party'
```

`typescript` ships `ThirdPartyNoticeText.txt` beside its Apache-2.0
`LICENSE.txt`, and `pyright` ships the Apache-2.0 typeshed stub library under
`dist/typeshed-fallback/LICENSE` inside its own MIT tree. Both are listed in
`licenseFileSubpaths` and appended below a separator by `LSPInstalledLicenses`.
Run that `grep` on every artifact of a bumped pin; a notice that appears and is
not listed ships unacknowledged, and nothing in `swift test` can see it. There is
nothing to run it against for `rust-analyzer` — a `.gz` has one member and it is
the binary — which is why that component's `licenseFileSubpaths` is empty and why
`LSPProvisioningManifestTests` pins the emptiness by id rather than letting it
read as an omission.

A second notice may also move the component's **`licenseSPDX`**, which is an
SPDX *expression* (`MIT AND Apache-2.0` for pyright) rather than a bare id, and
is rendered as the heading over the very texts below it. The line is whether the
notice is a *separate project's license file* — typeshed's Apache-2.0 `LICENSE`
is, so it is named; the third-party sections carried inside Node's own `LICENSE`
and `typescript`'s `ThirdPartyNoticeText.txt` are not, and are printed verbatim
under a single-id heading. `LSPProvisioningManifestTests` validates the
expression's operands and pins all three values by hand, because a wrong heading
compiles, passes every other check and mislabels a license on screen.

`swift test` then re-validates the shape of everything else, and the manual
checks at the end of the plan re-validate that the server actually answers.

## Known limits

- **A download is held whole in memory** (D14). The peak resident cost is the
  largest artifact — ~53 MB for Node, once, during a first install. There is no
  streaming, no progress reporting and no resume: a download interrupted at 90%
  starts again from zero when Retry is pressed.
- **Nothing caps the size of a response.** The manifest's `byteCount` is a
  *size shown to the user*, not a limit — nothing compares a response against it,
  and no ceiling is imposed on the body. An endpoint that streamed indefinitely
  would grow the app's memory until `URLSession`'s 20-minute resource timeout cut
  it off. Deliberate: a length check is strictly weaker than the SHA-256 that
  already gates the unpack, so a body of the wrong size installs nothing either
  way, and enforcing a ceiling would need the byte count threaded through the
  seam plus a chunked read for a case that requires a compromised TLS endpoint
  at `nodejs.org` or `registry.npmjs.org` to reach.
- **Deleting an install tree blocks the main actor.** `FileServicing` is
  synchronous and not `Sendable`, so the four `removeItem` sites — Settings →
  Remove, the post-upgrade sweep of older versions, the staging discard on a
  failed attempt, and `sweepStaging()` at launch — run on the main actor. Node's
  unpacked tree is ~110 MB across thousands of files, so a removal is a visible
  pause. Accepted rather than fixed: every one of them is either user-initiated
  or a launch-time sweep that normally finds nothing, and moving them off would
  mean making the file-service protocol `Sendable` across the whole app.
- **No proxy, mirror or registry configuration.** The URLs are the manifest's
  and nothing overrides them. A corporate TLS-intercepting proxy fails as an
  ordinary download failure (or, if it serves something else, as a checksum
  mismatch, which is the design working); an air-gapped machine fails the same
  way. Either leaves the row at "not installed" with Retry, and the language on
  tree-sitter.
- **The architecture is the build slice, not the machine.** A Rosetta-translated
  app reports `x64` and provisions x64 Node — correct, since the server process
  inherits the translation, but it means a translated app on Apple silicon
  installs the slower runtime. Not worked around: an arm64 child under a
  translated parent is the arrangement that would not work.
- **pyright without a Python interpreter analyses against bundled typeshed
  only.** Nothing here provisions Python itself; a project whose virtualenv
  pyright cannot find still answers, but knows nothing about installed packages.
- **macOS only.** iOS has no subprocess, so it installs nothing, registers
  nothing and shows neither the banner nor the Settings tab — the whole phase is
  behind `#if os(macOS)` on the app side, and the Core side is simply never
  composed there.
- **Nothing is verified after installation.** The digest is checked once, on the
  bytes as they arrive; the installed tree is not re-hashed at launch and there
  is no code signature or notarization check on what was unpacked. A user who
  edits the install root gets what they wrote.
- **The manifest is fixed at ship time, and a pin bump re-downloads.** A
  published version with a security fix reaches users only in a new app version:
  there is no update channel, and nothing checks for one. What a pin bump *does*
  do is make the old tree un-servable — every path names the version — so the
  component reads `absent` at the pinned version even though its predecessor is
  still on disk. For an `accepted` server that is by design the silent path
  (D15): the next `.ts`/`.py` tab opened after the app update runs
  `prepareForOpening`, which re-installs at the new pin without a banner and
  without asking, and `commit` then deletes the superseded tree
  (`removeOtherVersions`). So an app update whose pin moved costs the accepted
  user another ~52 MB on next use, unannounced except by the Settings row —
  which is the price of "accepted means keep it working" and the reason
  `LSPServerConsent.accepted` is worded as it is. Offline at that moment, the
  silent install fails, `failures` suppresses further attempts for the app run,
  and the language falls back to tree-sitter until Retry or the next launch. The
  stale directory stays removable either way.
- **One version at a time, and no per-project override.** A project needing a
  different `typescript` gets the workspace copy through D11's resolution order
  (which is what `fallbackPath` buys), but nothing else here is configurable: no
  per-project server, no extra initialization options, no arguments.

## Tests

`swift test` covers this layer end to end without a network or a `tar`:

- `SHA256Tests` — the published FIPS vectors, the multi-chunk equivalence and
  the padding-boundary sweep.
- `LSPProvisioningManifestTests` / `LSPInstallLayoutTests` — the pinned data and
  the path math, in the `DependencyPinTests` mould.
- `LSPInstallEngineTests` — every ordering and failure rule of D12–D14, over
  `Support/ScriptedInstallSeams.swift`: a downloader answering canned bytes (or
  an error, or blocking on a `Gate`) and counting calls, and an unpacker that
  materialises a canned tree into a `StubFileTree`. The canned bytes are derived
  from the URL rather than random, which is what lets a test assert that the
  bytes verified are the bytes unpacked.
- `LSPWorkspaceTests` — D16's swap, teardown and bookkeeping rules.
- `SettingsStoreTests` — consent round-tripping across a rebuilt store.
- `LSPProvisioningModelTests` — the consent rules, the published registry, and
  the equalities that pin the *absence* of interference: with nothing installed a
  Swift request routes exactly as in 2a and TypeScript/Python answer
  byte-identically to the bare tree-sitter provider, and installing one server
  changes neither of the others.
- `LSPSourceGatingTests` — the platform split by set equality over both sides:
  the app-side files open with `#if os(macOS)`, the Core-side ones import
  Foundation and nothing else and mention neither `Process` nor a platform
  framework. `SHA256` is in that sweep, so a later `import CryptoKit` fails here.
