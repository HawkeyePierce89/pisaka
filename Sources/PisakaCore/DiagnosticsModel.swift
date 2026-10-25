import Foundation

/// Observable state for the diagnostics channel: the store the editor overlay,
/// the gutter and the Problems panel read, plus the sync/revision bookkeeping
/// that decides which pushes may land (D31/D32).
///
/// Modelled on `SymbolIndexModel` — an `@MainActor` `ObservableObject` whose
/// value-type payload is republished wholesale, whose decisions are pure
/// helpers (`DiagnosticShift`, the acceptance gate below), and whose
/// composition is thin view-layer glue (`LSPDocumentSyncController` on macOS,
/// the app's `PisakaApp.init` wiring — this file knows neither).
///
/// **This model is a reader.** It never raises `autosave.suspend()` or
/// `localChanges.beginRevert()`, and it is never gated by them, for the symbol
/// index's stated reason: diagnostics only *look* at buffers, write nothing to
/// disk, and a set landing mid-revert costs at worst one wrong squiggle that
/// the next 400 ms sync's push corrects. A reader that took the writer gate
/// would serialize the editor behind every language-server push for no benefit.
///
/// ## The acceptance gate (D32)
///
/// A push is accepted into the store only when **both** hold:
///
/// * its version is the one recorded at the document's last reported sync
///   (`noteSynced`) — absent on the push means "unversioned", which most
///   servers send, and then only the revision half speaks;
/// * the buffer revision recorded at that sync still equals the document's
///   *current* revision — i.e. nothing was typed between that sync and this
///   push.
///
/// The second half is what makes staleness self-correcting rather than
/// replayed: a push computed against text the buffer has moved past is dropped
/// outright, and the last keystroke has already scheduled one more sync whose
/// push will have no edits after it. The same gate silently covers the folder
/// switch — `prepareForFolderChange(root:)` clears the bookkeeping along with the
/// store, so no push can be accepted until the controller re-syncs the buffer
/// against whatever server serves the new folder. Edits *after* an accepted
/// push shift the stored set incrementally (`DiagnosticShift.updated`),
/// dropping what the edit touched; a wholesale buffer replacement clears the
/// document's mapped set outright.
///
/// ## The positional lane: documents no buffer holds
///
/// A server may report on a file no tab holds. That report arrives as
/// `.positional`, carrying the server's own positions, and it skips the gate
/// entirely — there is no sync to compare it with and no buffer it could be
/// stale against — so it replaces the document's entry wholesale, with no hold.
/// It is dropped only when a sync record *exists* for the document: then a
/// buffer is open and the mapped lane is the document's one answerer. Closing
/// the last tab drops the bookkeeping (sync record, revision, hold) and keeps
/// whatever set the store holds, so the panel and the tree keep the file's
/// problems after the close. A wholesale replacement drops only a mapped entry,
/// which is what lets a file being opened keep its positional record until the
/// first mapped report replaces it.
///
/// ## What bounds what
///
/// The bookkeeping — sync records, revisions, holds — is bounded by the open
/// tabs: every one of them is dropped when the document's last tab closes.
/// The store is not: it is bounded by what the servers report about the
/// current folder, and emptied by a server's teardown and by the folder change.
///
/// ## The tree's lookup
///
/// The project tree reads one value of this model: ``TreeDiagnostics``, the
/// worst severity at or below each row, kept current from the store's
/// `didSet` against the opened folder's two spellings, which
/// ``prepareForFolderChange(root:)`` resolves once. A mutation confined to one
/// document — every push, every keystroke's shift, every replacement — moves
/// that file's mark through ``TreeDiagnosticsIndex``, visiting only its
/// ancestry; only the bulk clears (a server's teardown, a removal, the folder
/// change) rebuild, because a rebuild per push re-derives every diagnosed
/// file's key in exactly the workspace-wide burst this lookup exists for. The
/// tree retains the snapshot it was handed, so a move that changes the
/// published value copies what it writes through — the marks table is a
/// persistent trie, so that is the written keys' paths, logarithmic in the
/// marked keys, never the table. It is published apart from
/// the store, by ``TreeDiagnosticsHolder``, because the store republishes on
/// every keystroke's shift and the tree must not re-render with it: the holder
/// assigns only a value that differs from the one it holds, and a shift that
/// keeps every file's worst severity builds an equal lookup. With no folder
/// the lookup is ``TreeDiagnostics/empty``.
///
/// ## Pushes that beat their own sync (the hold-and-reconcile step)
///
/// There are two moments where a failed gate means something other than stale:
/// the windows between the workspace committing a flushed version and the
/// controller's task resuming far enough to report `noteSynced` — several main
/// -actor hops after the bytes went out, during which a fast server's publish
/// can arrive. Dropping such a push strands the document blank until the next
/// keystroke or tab switch, which on a freshly opened file is exactly the
/// first-diagnosis moment the feature exists for. So a push is **held** (one
/// per document, newest wins) when it finds no record at all, or a record
/// pinned to a revision the buffer has moved past — the signature of a report
/// still in flight, whether the push it belongs to outran it or a predecessor
/// report has not been superseded yet. It is judged when the next record
/// lands: accepted only if that sync itself is current (its pinned revision
/// equals the buffer's) and the push's version matches it — an absent version
/// passes on the revision half alone, as everywhere else. Every invalidating
/// event drops the hold — an edit (the held set predates text nobody can
/// shift it across), a wholesale replacement, either clear, and the folder
/// change — so a hold can never resurrect anything a teardown or a keystroke
/// has already condemned. A version mismatch against a **current** record is
/// held too, for the same reason rather than against it: with no keystroke to
/// point at, the mismatching version is either a late replay — which the
/// reconcile's version half then discards unreplayed — or the settling flush's
/// own publish beating its report home, which it admits. One honest trade
/// remains: a held push carrying no version may rarely describe the previous
/// sync's text (a provider flush racing the settling one); accepting it can
/// draw one misplaced set for the instant before the answer to the settling
/// sync replaces it — the same briefly-wrong-over-blank trade D32 already
/// makes, self-correcting by the push that answer is guaranteed to provoke.
@MainActor
public final class DiagnosticsModel: ObservableObject {
    /// What one successful sync recorded: the server version the workspace
    /// acknowledged for the document, and the buffer revision at which that
    /// acknowledgement happened. Both are read by the acceptance gate; both die
    /// with the generation.
    public struct SyncRecord: Equatable, Sendable {
        public let version: Int
        public let revision: Int

        public init(version: Int, revision: Int) {
            self.version = version
            self.revision = revision
        }
    }

    /// Every document's current set, republished on every mutation so the three
    /// surfaces (overlay, gutter, panel) observe one truth.
    @Published public private(set) var store = DiagnosticStore() {
        didSet {
            notePanelRowsChanged()
            refreshTreeDiagnostics()
        }
    }

    /// The project tree's lookup, published on its own and only when it
    /// changes — see "The tree's lookup" on the type.
    public let treeDiagnostics = TreeDiagnosticsHolder()

    /// The opened folder's two spellings, resolved once per folder change; `nil`
    /// until the first one, when the lookup stays empty.
    private var treeRoot: TreeDiagnostics.Root?

    /// The lookup's incremental bookkeeping, `nil` with no folder open.
    /// Internal so a test can read its step count.
    private(set) var treeIndex: TreeDiagnosticsIndex?

    /// The one document the store mutation in progress touches, set by
    /// ``mutateStore(touching:_:)``; `nil` while any other mutation runs, which
    /// is what sends the store's `didSet` to a full rebuild.
    private var treeTouch: URL?

    /// Full rebuilds of the tree's lookup so far — the seam the "one document's
    /// mutation never rebuilds" rule is pinned through.
    private(set) var treeRebuilds = 0

    /// Per-document sync records, keyed by standardized URL — cleared by
    /// `prepareForFolderChange(root:)`, per-document by `noteBufferReplaced(url:)`,
    /// and dropped outright when the document's last tab closes
    /// (``noteDocumentClosed(url:)``). A record's existence is also what closes
    /// the positional lane for its document.
    private var syncs: [URL: SyncRecord] = [:]
    /// Per-document buffer revisions. Bumped by every edit and every wholesale
    /// replacement; compared by the gate against the revision pinned at sync
    /// time. Implicitly zero until first touched, and dropped again with the
    /// sync record when the document closes — so both maps stay bounded by the
    /// open tabs rather than by every file the session ever opened.
    private var revisions: [URL: Int] = [:]

    /// A push that arrived before its document's bookkeeping could accept it —
    /// the routed-before-reported race documented on the type. One per
    /// document, newest wins.
    ///
    /// The event alone, with no revision beside it: the hold's *survival* is
    /// already the proof that the buffer stood still across it, because every
    /// revision bump (`noteEdit`, `noteBufferReplaced`, `prepareForFolderChange`)
    /// drops the hold. Held only between the push and the next event that
    /// touches the document; never replayed after an invalidation.
    private var heldPushes: [URL: LSPDiagnosticEvent] = [:]

    /// The paths the app removed or moved away since the folder opened, as
    /// standardized components — ``noteItemRemoved(at:)``'s tombstones. A
    /// positional report at or under one is accepted only if the file it names
    /// exists again as a file (`fileExists`), so a report the server queued before the
    /// removal, or a stale one from a server never told about it, cannot
    /// resurrect the path. Cleared by the folder change; an exact tombstone
    /// whose path exists again is lifted at the probe.
    private var removedPaths: [[String]] = []

    /// The existence probe behind the tombstones — the one file-system call
    /// in this model, made only for a positional report at or under a removed
    /// path. A seam so a test can answer it without a disk; the default is
    /// ``isFile(_:)``, so a folder recreated at a removed file's path does not
    /// count as the file coming back.
    private let fileExists: (URL) -> Bool

    /// The Problems panel's groups as last built for `root`, plus the
    /// documents a one-document mutation has touched since. The store
    /// republishes on every push and every keystroke's shift, and the panel
    /// re-reads ``rows(relativeTo:)`` on each: rebuilding every file's rows —
    /// sorting each set, standardizing each path — per publication is what a
    /// workspace-wide server's per-file burst turns quadratic. So only the
    /// touched documents are rebuilt and merged back in; a bulk clear drops
    /// the cache whole.
    private var panelRows: (root: URL, groups: [DiagnosticStore.FileRows])?
    private var panelDirty: Set<URL> = []

    /// Documents whose rows ``rows(relativeTo:)`` has built since this model
    /// was made — the seam the "a push rebuilds only its own file's rows" rule
    /// is pinned through, counted apart from the groups it returns.
    private(set) var panelFileBuilds = 0

    public init(fileExists: @escaping (URL) -> Bool = DiagnosticsModel.isFile) {
        self.fileExists = fileExists
    }

    /// Whether something other than a directory exists at `url` — diagnostics
    /// are about files, and a directory at a tombstoned path names none.
    public nonisolated static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    // MARK: - The tree's lookup

    /// Mutate the store where the change is confined to `url`'s entry, so the
    /// tree's lookup is moved for that one file instead of rebuilt.
    private func mutateStore(touching url: URL, _ body: (inout DiagnosticStore) -> Void) {
        treeTouch = url
        defer { treeTouch = nil }
        body(&store)
    }

    /// The store's `didSet`, for the panel: a one-document mutation marks that
    /// document's group stale; anything else drops the cached groups.
    private func notePanelRowsChanged() {
        if let url = treeTouch {
            panelDirty.insert(url.standardizedFileURL)
        } else {
            panelRows = nil
            panelDirty.removeAll()
        }
    }

    /// The store's `didSet`: one document's mutation records that file's new
    /// mark, anything else rebuilds; the holder hears only a changed lookup.
    private func refreshTreeDiagnostics() {
        guard let treeRoot else { return }
        if let url = treeTouch, treeIndex != nil {
            guard treeIndex?.record(TreeDiagnostics.mark(of: store.entry(for: url)), for: url) == true
            else { return }
        } else {
            treeRebuilds += 1
            treeIndex = TreeDiagnosticsIndex(store: store, root: treeRoot)
        }
        treeDiagnostics.update(treeIndex?.lookup ?? .empty)
        treeIndex?.notePublished()
    }

    // MARK: - Sync bookkeeping (fed by LSPDocumentSyncController)

    /// The document's current buffer revision — what ``noteEdit`` and
    /// ``noteBufferReplaced(url:)`` bump, and zero for a document nothing has
    /// touched yet.
    ///
    /// The one thing the sync controller reads of this model, and it reads it
    /// **once, synchronously**, at the moment it schedules a flush — the
    /// generation-token rule. Everything the flush does afterwards happens
    /// across hops the pin cannot span, so a sync racing a keystroke records
    /// the *old* revision and the acceptance gate rejects its pushes until the
    /// next debounce re-syncs; see ``noteSynced(url:version:revision:)``.
    public func currentRevision(for url: URL) -> Int {
        revisions[url.standardizedFileURL] ?? 0
    }

    /// Record that `url` was flushed to its server: the server now holds
    /// `version`, and the buffer stood at `revision` when the flush began.
    ///
    /// `revision` is pinned by the caller *synchronously before its hop* (the
    /// controller's contract), so a sync that raced a keystroke records the old
    /// revision — and its pushes are then rejected by the gate until the next
    /// debounce re-syncs. Recording anyway (rather than refusing) keeps the
    /// last-known sync truthful; rejecting is the gate's decision, not the
    /// recorder's.
    ///
    /// Recording is also when a held push is judged: this record is the one it
    /// was waiting for. Accepted only when this sync itself is current (its
    /// pinned revision equals the buffer's — otherwise the held set describes
    /// text the buffer has moved past) and its version matches (absent passes,
    /// as everywhere). The hold's own survival already proves nothing was
    /// typed since the hold — every revision bump (`noteEdit`,
    /// `noteBufferReplaced`, `prepareForFolderChange`) drops it, which is why
    /// the reconcile never re-checks the hold-time revision — so together the
    /// clauses pin the set to exactly the text this sync delivered.
    public func noteSynced(url: URL, version: Int, revision: Int) {
        let key = url.standardizedFileURL
        syncs[key] = SyncRecord(version: version, revision: revision)

        // `heldURL`, not the parameter: the two standardize identically (the
        // hold is filed under a key derived from the event's own URL), and
        // naming them apart is what keeps that a fact a reader can check rather
        // than one a shadowed binding hides.
        if let held = heldPushes.removeValue(forKey: key),
           case .published(let heldURL, let serverID, let root, let heldVersion, let diagnostics) = held,
           revision == (revisions[key] ?? 0),
           heldVersion.map({ $0 == version }) ?? true {
            mutateStore(touching: heldURL) {
                $0.replace(
                    url: heldURL,
                    serverKey: DiagnosticStore.ServerKey(serverID: serverID, root: root),
                    diagnostics: diagnostics
                )
            }
        }
    }

    /// One edit landed in `url`'s buffer: shift the stored set across it and
    /// bump the revision (D32).
    ///
    /// The tables are the ruler's pre/post line-start arrays at the moment of
    /// the edit, exactly as ``BlameShift`` consumes them. Inconsistent input
    /// shifts to `[]` — honest "unknown" — never a drifted set.
    public func noteEdit(
        url: URL,
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) {
        let key = url.standardizedFileURL
        revisions[key] = (revisions[key] ?? 0) + 1
        // A held push predates the edit: its set cannot be shifted across text
        // nobody mapped for it, so it is honest "unknown" like any other
        // touched content (D32). The settling sync's republish replaces it.
        heldPushes[key] = nil
        // Read before writing, and skipped entirely when there is nothing to
        // shift. `apply(shift:to:)` already no-ops for an unknown document, but
        // *calling* it is a mutating access to a `@Published` value and so
        // publishes regardless — one `objectWillChange` per keystroke in every
        // undiagnosed file, waking the Problems panel's rows and counts and the
        // editor's whole-document gutter pass for a store that did not change.
        // A read is not a mutation, so the guard costs nothing and the
        // behaviour is identical.
        //
        // The **empty** entry is guarded out for the same reason and is the
        // more common of the two: an all-clear push installs an entry holding
        // no diagnostics (`DiagnosticStore.replace`), so a clean served file
        // being typed in — the steady state of every file that compiles — is
        // exactly the case the first clause misses. Shifting an empty set can
        // only produce an empty set, so skipping is behaviour-preserving here
        // too.
        // A positional entry is guarded out by type: `mapped` is `nil` for it,
        // and a shift is defined over buffer offsets it does not carry.
        guard let existing = store.entry(for: url)?.mapped, !existing.isEmpty else { return }
        let shifted = DiagnosticShift.updated(
            existing,
            previousLineStarts: previousLineStarts,
            newLineStarts: newLineStarts,
            editedRange: editedRange,
            changeInLength: delta
        )
        mutateStore(touching: url) { $0.apply(shift: shifted, to: url) }
    }

    /// The buffer behind `url` was replaced wholesale — tab switch,
    /// `reloadFromDisk`, project Replace All, merge apply — so the document's
    /// mapped set is dropped outright and its sync record with it: the server
    /// no longer holds text anyone mapped a push against (D32). A positional
    /// entry stays: it never described a buffer, so replacing one cannot have
    /// made it stale, and the first mapped report replaces it.
    public func noteBufferReplaced(url: URL) {
        let key = url.standardizedFileURL
        revisions[key] = (revisions[key] ?? 0) + 1
        syncs[key] = nil
        heldPushes[key] = nil
        mutateStore(touching: url) { $0.clearMapped(url: url) }
    }

    /// An editor is about to show `url`'s buffer — a tab switch, which is also
    /// how a reopened file first appears: drop a mapped set the document's
    /// closed predecessor left behind, and nothing else.
    ///
    /// Such a set is recognised by having **no sync record**: a mapped entry is
    /// only ever accepted against one, and every way a record goes either takes
    /// the mapped set with it (``noteBufferReplaced(url:)``, the folder change)
    /// or is the close (``noteDocumentClosed(url:)``), which keeps the set on
    /// purpose. So a mapped set with no record describes the buffer of a tab
    /// that has closed, and its offsets may name text the file no longer holds —
    /// it changed on disk while closed, or the close discarded edits. The editor
    /// treats a first showing as a plain tab switch, which keeps a set, so this
    /// is the call that drops it. A document whose record survives — a tab
    /// merely switched back to — keeps its set, as a plain switch must, and a
    /// positional entry stays either way, as on every replacement.
    ///
    /// Only the entry goes — no revision bump, no hold dropped: with no record
    /// there is no sync for a bump to condemn, and leaving the bookkeeping alone
    /// is what makes the call safe on either side of the showing's own
    /// immediate sync being scheduled.
    public func noteDocumentShown(url: URL) {
        guard syncs[url.standardizedFileURL] == nil, store.entry(for: url)?.mapped != nil else { return }
        mutateStore(touching: url) { $0.clearMapped(url: url) }
    }

    // MARK: - The push channel

    /// Receive one event from the workspace's sink.
    ///
    /// A `published` passes the acceptance gate documented on the type or is
    /// dropped — silently, like everything else in this layer — except the
    /// bookkeeping-lag states that earn the hold-and-reconcile step: a push
    /// with no record, or against a record pinned to a revision the buffer has
    /// moved past, is held for the next record's landing instead of dropped,
    /// because both mean the push may belong to a sync whose report is still in
    /// flight. So is a version mismatch against a *current* record: with no
    /// keystroke to condemn it, the push is either a late replay (the
    /// reconcile's version half discards it) or the settling flush's own
    /// publish arriving ahead of its report (the reconcile admits it).
    ///
    /// A `positional` skips the gate: it is dropped when a sync record exists
    /// for the document (a buffer is open, so the mapped lane answers), and
    /// otherwise replaces the entry wholesale under the same provenance, with
    /// no hold — and no existing hold is touched, since a hold waits for a
    /// record this push neither brings nor removes.
    ///
    /// The clears are applied as they come; each teardown path emits exactly
    /// one, and a late duplicate after a folder change finds nothing to clear.
    public func receive(_ event: LSPDiagnosticEvent) {
        switch event {
        case .published(let url, let serverID, let root, let version, let diagnostics):
            let key = url.standardizedFileURL
            let currentRevision = revisions[key] ?? 0
            guard let sync = syncs[key] else {
                heldPushes[key] = event
                return
            }
            guard sync.revision == currentRevision else {
                // The record predates the buffer's present state: its own
                // pushes are stale by the live clause, and this push may be
                // the in-flight sync's answer. Hold it for that report.
                heldPushes[key] = event
                return
            }
            guard version.map({ $0 == sync.version }) ?? true else {
                // The record is current but names another version: either a
                // late replay of an older push or the settling flush's own
                // publish beating its report home. Holding costs nothing —
                // the reconcile's version half admits only the version that
                // record actually lands with.
                heldPushes[key] = event
                return
            }
            heldPushes[key] = nil
            mutateStore(touching: url) {
                $0.replace(
                    url: url,
                    serverKey: DiagnosticStore.ServerKey(serverID: serverID, root: root),
                    diagnostics: diagnostics
                )
            }
        case .positional(let url, let serverID, let root, let diagnostics):
            guard syncs[url.standardizedFileURL] == nil, !isRemovedAndGone(url) else { return }
            mutateStore(touching: url) {
                $0.replace(
                    url: url,
                    serverKey: DiagnosticStore.ServerKey(serverID: serverID, root: root),
                    positional: diagnostics
                )
            }
        case .cleared(.server(let serverID, let root)):
            store.clear(serverKey: DiagnosticStore.ServerKey(serverID: serverID, root: root))
            // The teardown condemns everything that server produced, whatever
            // stage of the gate it had reached; a different server's holds are
            // not touched.
            heldPushes = heldPushes.filter { _, held in
                guard case .published(_, let heldServerID, let heldRoot, _, _) = held
                else { return true }
                return heldServerID != serverID || heldRoot != root
            }
        case .cleared(.document(let url)):
            noteDocumentClosed(url: url)
        }
    }

    /// The document left the editor: forget all of its bookkeeping, and keep
    /// its set.
    ///
    /// Every record describing it is now about a life nobody is looking at —
    /// the sync record names a version of a document no workspace holds open,
    /// and the revision it would be compared against belongs to a buffer that
    /// is gone. Dropping all of it is what keeps the maps bounded by the *open*
    /// tabs rather than by every file the session ever touched, and it means a
    /// file reopened later is gated from zero instead of against its
    /// predecessor's numbers. With the record gone, the document's positional
    /// lane opens, so the server's next report about the closed file lands.
    ///
    /// The store entry is deliberately left alone: the file's problems are still
    /// the file's problems after its tab closes, and the Problems panel and the
    /// tree keep listing them. A kept **mapped** set is dropped when the file is
    /// shown again (``noteDocumentShown(url:)``), its offsets describing a
    /// buffer that is gone.
    ///
    /// Reached two ways, and it needs both. `LSPWorkspace.didClose(url:)` emits
    /// `.cleared(.document)` only for a URI it still *held* — every teardown
    /// path (a death, a shutdown, an un-registration) wipes its document table
    /// first, so a crash-then-close sequence emits nothing at all. The app
    /// therefore calls this directly from the same "no tab shows this file any
    /// more" guard that fires the `didClose`, which is also what bounds the
    /// revision map for files no server ever served: `noteEdit` mints a
    /// revision for any buffer that is typed in, served or not, and only a
    /// close prunes it. Idempotent, so arriving both ways costs nothing.
    public func noteDocumentClosed(url: URL) {
        let key = url.standardizedFileURL
        heldPushes[key] = nil
        syncs[key] = nil
        revisions[key] = nil
    }

    /// The app removed or moved away the file or folder at `url` — a project-tree
    /// delete, rename or move, or a git operation that deleted an open file —
    /// so every entry at or under the old path goes, both kinds.
    ///
    /// A close keeps the set because the file is still there to have problems;
    /// a removal is the case where it is not, and the app is the one that knows
    /// it, so nothing waits for a server to report on a path that no longer
    /// exists (D46). Bookkeeping is the close's business
    /// (``noteDocumentClosed(url:)``), which the same call sites already reach.
    public func noteItemRemoved(at url: URL) {
        removedPaths.append(url.standardizedFileURL.pathComponents)
        store.clear(under: url)
    }

    /// Whether `url` lies at or under a path the app removed and names no file
    /// now. Compared lexically by whole component, exactly as the removal's own
    /// clear compares, and the disk is asked only once that matches.
    private func isRemovedAndGone(_ url: URL) -> Bool {
        guard !removedPaths.isEmpty else { return false }
        let components = url.standardizedFileURL.pathComponents
        guard removedPaths.contains(where: {
            components == $0 || CanonicalPath.relativeComponents(of: components, under: $0) != nil
        }) else { return false }
        guard fileExists(url) else { return true }
        removedPaths.removeAll { $0 == components }
        return false
    }

    /// The folder changed to `root`: record its two spellings for the tree's
    /// lookup, then clear everything — both kinds of entry — and
    /// invalidate every sync record, so no mapped push routed from an old
    /// project's server can land (the gate does the dropping; this method just
    /// removes anything it could have matched).
    ///
    /// There is deliberately no separate generation counter here: the *working*
    /// gate is the cleared bookkeeping itself — after this call no sync record
    /// survives, so no mapped push can pass until the controller records a
    /// fresh one. A positional push needs no record, and the workspace forwards
    /// one only from a live session serving the current root, so an old
    /// project's report never reaches this model as one.
    ///
    /// Called in the same main-actor turn as
    /// `LSPWorkspace.prepareForFolderChange(root:)` — synchronously, before any
    /// hop, like every generation pin in this codebase. The root is recorded
    /// before the store is emptied, so the clear's own rebuild publishes the
    /// empty lookup in that same turn; resolving the canonical spelling is the
    /// lookup's one file-system call, made here and never per build or per row.
    public func prepareForFolderChange(root: URL) {
        treeRoot = TreeDiagnostics.Root(root)
        syncs.removeAll()
        revisions.removeAll()
        heldPushes.removeAll()
        removedPaths.removeAll()
        store.clearAll()
    }

    // MARK: - Read-only queries (the views' whole surface)

    /// Every diagnostic currently held for `url`, in the store's own (arrival)
    /// order — the editor overlay's lookup. The squiggle needs each diagnostic's
    /// exact buffer range and severity, which the per-line worst-severity query
    /// deliberately flattens away; overlap resolution into painted runs is the
    /// view layer's (`BracketOverlayLayoutManager.setDiagnosticRuns`).
    public func diagnostics(in url: URL) -> [Diagnostic] {
        store.entry(for: url)?.mapped ?? []
    }

    /// Every diagnostic of `url` whose range contains `offset`, ordered by
    /// ``Diagnostic/orderingKey`` — hover's lookup (D34).
    public func diagnostics(at offset: Int, in url: URL) -> [Diagnostic] {
        store.diagnostics(at: offset, in: url)
    }

    /// Worst severity per line at exactly `lineCount` entries — the gutter's
    /// marker column, indexed by line. See `DiagnosticStore.worstSeverityPerLine`
    /// for why `lineStarts` travels with the call.
    public func worstSeverityPerLine(
        url: URL,
        lineCount: Int,
        lineStarts: [Int]
    ) -> [DiagnosticSeverity?] {
        store.worstSeverityPerLine(url: url, lineCount: lineCount, lineStarts: lineStarts)
    }

    /// The Problems panel's rows, grouped by file in reading order — the
    /// store's ``DiagnosticStore/rows(relativeTo:)`` answer, kept incrementally:
    /// the documents touched since the last read are rebuilt and merged into
    /// the cached groups (see `panelRows`), and a different root or a bulk
    /// mutation builds the whole list again.
    public func rows(relativeTo root: URL) -> [DiagnosticStore.FileRows] {
        guard let cached = panelRows, cached.root == root else {
            let groups = store.rows(relativeTo: root)
            panelFileBuilds += store.entriesByURL.count
            panelRows = (root, groups)
            panelDirty.removeAll()
            return groups
        }
        guard !panelDirty.isEmpty else { return cached.groups }
        let dirty = panelDirty
        panelDirty.removeAll()
        panelFileBuilds += dirty.count
        let kept = cached.groups.filter { !dirty.contains($0.url) }
        let fresh = dirty
            .compactMap { store.fileRows(for: $0, relativeTo: root) }
            .sorted(by: DiagnosticStore.FileRows.precedes)
        let groups = Self.merge(kept, fresh)
        panelRows = (root, groups)
        return groups
    }

    /// Two lists already in ``DiagnosticStore/FileRows/precedes(_:_:)`` order,
    /// merged into one in that order.
    private static func merge(
        _ lhs: [DiagnosticStore.FileRows],
        _ rhs: [DiagnosticStore.FileRows]
    ) -> [DiagnosticStore.FileRows] {
        guard !rhs.isEmpty else { return lhs }
        var merged: [DiagnosticStore.FileRows] = []
        merged.reserveCapacity(lhs.count + rhs.count)
        var left = 0
        var right = 0
        while left < lhs.count, right < rhs.count {
            if DiagnosticStore.FileRows.precedes(rhs[right], lhs[left]) {
                merged.append(rhs[right])
                right += 1
            } else {
                merged.append(lhs[left])
                left += 1
            }
        }
        merged.append(contentsOf: lhs[left...])
        merged.append(contentsOf: rhs[right...])
        return merged
    }

    /// Errors and warnings across every document — the panel header's numbers.
    public var counts: DiagnosticStore.Counts {
        store.counts
    }
}

/// The holder the project tree observes for ``TreeDiagnostics``, owned by
/// ``DiagnosticsModel`` and fed from its store's `didSet`.
///
/// A separate object, not a second `@Published` on the model, because
/// observing the model means observing the store, which republishes on every
/// keystroke's shift; this one emits only when the lookup actually changes.
@MainActor
public final class TreeDiagnosticsHolder: ObservableObject {
    /// The current lookup — `.empty` until a folder is open and something in
    /// it is an error or a warning.
    @Published public private(set) var lookup: TreeDiagnostics = .empty

    init() {}

    /// Take `newLookup`, assigning — and so publishing — only when it differs
    /// from the held value.
    func update(_ newLookup: TreeDiagnostics) {
        guard newLookup != lookup else { return }
        lookup = newLookup
    }
}
