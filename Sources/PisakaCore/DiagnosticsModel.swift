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
/// switch — `prepareForFolderChange()` clears the bookkeeping along with the
/// store, so no push can be accepted until the controller re-syncs the buffer
/// against whatever server serves the new folder. Edits *after* an accepted
/// push shift the stored set incrementally (`DiagnosticShift.updated`),
/// dropping what the edit touched; a wholesale buffer replacement clears the
/// document's set outright.
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
    @Published public private(set) var store = DiagnosticStore()

    /// Per-document sync records, keyed by standardized URL — cleared by
    /// `prepareForFolderChange()` and per-document by `noteBufferReplaced(url:)`.
    private var syncs: [URL: SyncRecord] = [:]
    /// Per-document buffer revisions. Bumped by every edit and every wholesale
    /// replacement; compared by the gate against the revision pinned at sync
    /// time. Implicitly zero until first touched.
    private var revisions: [URL: Int] = [:]

    public init() {}

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
    public func noteSynced(url: URL, version: Int, revision: Int) {
        syncs[url.standardizedFileURL] = SyncRecord(version: version, revision: revision)
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
        let shifted = DiagnosticShift.updated(
            store.entry(for: url)?.diagnostics ?? [],
            previousLineStarts: previousLineStarts,
            newLineStarts: newLineStarts,
            editedRange: editedRange,
            changeInLength: delta
        )
        store.apply(shift: shifted, to: url)
    }

    /// The buffer behind `url` was replaced wholesale — tab switch,
    /// `reloadFromDisk`, project Replace All, merge apply — so the document's
    /// set is dropped outright and its sync record with it: the server no
    /// longer holds text anyone mapped a push against (D32).
    public func noteBufferReplaced(url: URL) {
        let key = url.standardizedFileURL
        revisions[key] = (revisions[key] ?? 0) + 1
        syncs[key] = nil
        store.clear(url: url)
    }

    // MARK: - The push channel

    /// Receive one event from the workspace's sink.
    ///
    /// A `published` passes the acceptance gate documented on the type or is
    /// dropped — silently, like everything else in this layer. The clears are
    /// applied as they come; each teardown path emits exactly one, and a late
    /// duplicate after a folder change finds nothing to clear.
    public func receive(_ event: LSPDiagnosticEvent) {
        switch event {
        case .published(let url, let serverID, let root, let version, let diagnostics):
            let key = url.standardizedFileURL
            guard let sync = syncs[key],
                  sync.revision == (revisions[key] ?? 0) else { return }
            if let version, version != sync.version { return }
            store.replace(
                url: url,
                serverKey: DiagnosticStore.ServerKey(serverID: serverID, root: root),
                diagnostics: diagnostics
            )
        case .cleared(.server(let serverID, let root)):
            store.clear(serverKey: DiagnosticStore.ServerKey(serverID: serverID, root: root))
        case .cleared(.document(let url)):
            store.clear(url: url)
        }
    }

    /// The folder changed: clear everything and invalidate every sync record,
    /// so no push routed from an old project's server can land (the gate does
    /// the dropping; this method just removes anything it could have matched).
    ///
    /// There is deliberately no separate generation counter here: the *working*
    /// gate is the cleared bookkeeping itself — after this call no sync record
    /// survives, so no push can pass until the controller records a fresh one.
    ///
    /// Called in the same main-actor turn as
    /// `LSPWorkspace.prepareForFolderChange(root:)` — synchronously, before any
    /// hop, like every generation pin in this codebase.
    public func prepareForFolderChange() {
        syncs.removeAll()
        revisions.removeAll()
        store.clearAll()
    }

    // MARK: - Read-only queries (the views' whole surface)

    /// Every diagnostic currently held for `url`, in the store's own (arrival)
    /// order — the editor overlay's lookup. The squiggle needs each diagnostic's
    /// exact buffer range and severity, which the per-line worst-severity query
    /// deliberately flattens away; overlap resolution into painted runs is the
    /// view layer's (`BracketOverlayLayoutManager.setDiagnosticRuns`).
    public func diagnostics(in url: URL) -> [Diagnostic] {
        store.entry(for: url)?.diagnostics ?? []
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

    /// The Problems panel's rows, grouped by file in reading order.
    public func rows(relativeTo root: URL) -> [DiagnosticStore.FileRows] {
        store.rows(relativeTo: root)
    }

    /// Errors and warnings across every document — the panel header's numbers.
    public var counts: DiagnosticStore.Counts {
        store.counts
    }
}
