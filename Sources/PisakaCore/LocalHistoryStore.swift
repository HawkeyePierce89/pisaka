import Foundation

/// The disk half of Local History: the one type that lists, reads, writes and
/// prunes snapshots, expressed entirely in terms of `FileServicing`,
/// `LocalHistoryLayout` (where things go) and `LocalHistoryPolicy` (whether they
/// go there at all).
///
/// **A value type with synchronous, `nonisolated` methods**, the
/// `SymbolIndexModel` shape: nothing here hops, so *the caller owns the hop*.
/// The capture model runs these on a private queue for every ordinary capture,
/// and the quit path — where a `Task` is not guaranteed to run before the
/// process exits — calls the very same methods inline on the main actor. A store
/// that owned an actor of its own could not offer that second guarantee, and a
/// store that were `async` would make the quit-time write impossible to state.
///
/// **Every failure is silent.** Local History runs behind ordinary work: a
/// listing that cannot be read is an empty history, a write that cannot land
/// loses one revision, a delete that fails leaves one file to be reclaimed by
/// the next prune. Nothing here throws and nothing reports, because there is no
/// answer a user could give — the `LeetCodeCatalog` degrading-write rule, for
/// the same reason.
///
/// **A snapshot appears in one `move`.** Bytes are written under a
/// non-parsing temporary name and renamed into place, so a listing never sees a
/// half-written revision: an interrupted capture leaves a `.partial` file that
/// listing ignores and retention ignores, and that the sweep
/// (`pruneAll(now:)`) reclaims — nothing else can, precisely because
/// everything else looks through it. This is `LSPInstallEngine`'s atomicity rule
/// at the scale of one file.
///
/// **A writer only of its own directory.** Every path this deletes is asserted
/// to be inside `layout.base` first; nothing here touches the user's files, so
/// it takes no `autosave.suspend()` / `localChanges.beginRevert()` gate and is
/// not gated by one.
public struct LocalHistoryStore {
    public let layout: LocalHistoryLayout
    public let policy: LocalHistoryPolicy
    private let fileService: FileServicing

    public init(
        layout: LocalHistoryLayout,
        fileService: FileServicing,
        policy: LocalHistoryPolicy = LocalHistoryPolicy()
    ) {
        self.layout = layout
        self.fileService = fileService
        self.policy = policy
    }

    /// What a half-written snapshot is called while it is being written. It ends
    /// in something other than `LocalHistoryLayout.snapshotExtension`, which is
    /// the whole mechanism: `snapshot(fromFileName:)` refuses it, so listing and
    /// retention both look straight through it.
    ///
    /// Derived from the destination name rather than randomised so that a second
    /// attempt at the *same* revision reuses (and overwrites) the same temporary
    /// rather than accumulating debris — and so a test can name the file it wants
    /// to fail.
    static let temporarySuffix = ".partial"

    // MARK: - Reading

    /// One file's stored revisions, newest first.
    ///
    /// **One directory read and no content reads** — the property the whole
    /// layout exists to buy. A missing directory (the overwhelmingly common case:
    /// most files in a project have no history) is an empty list, never an error,
    /// and so is an unreadable one.
    ///
    /// Entries are recognised by *name*: anything that does not parse — a foreign
    /// file, a `.partial` from an interrupted write, a tag some future version
    /// invents — is ignored and left where it is. The URLs the listing hands back
    /// are deliberately not used to read anything: `FileManager` resolves the
    /// parent's symlinks in them (`StubFileTree.listingSpelling` stages exactly
    /// that), so every read here re-derives its URL from the layout.
    public nonisolated func revisions(root: URL, relativePath: String) -> [LocalHistorySnapshot] {
        let directory = layout.fileDirectory(forRoot: root, relativePath: relativePath)
        return LocalHistorySnapshot.sortedNewestFirst(snapshots(in: directory))
    }

    /// One revision's text, or `nil` when it is no longer there.
    ///
    /// `nil` rather than a throw for the same reason as everywhere else here, and
    /// it is genuinely reachable: retention can delete a revision between the
    /// listing the window is showing and the row the user clicks.
    public nonisolated func content(
        of snapshot: LocalHistorySnapshot,
        root: URL,
        relativePath: String
    ) -> String? {
        let directory = layout.fileDirectory(forRoot: root, relativePath: relativePath)
        return try? fileService.read(url: directory.appendingPathComponent(snapshot.fileName))
    }

    // MARK: - Capturing

    /// Store `text` as the next revision of `relativePath`, unless the policy says
    /// otherwise; the stored snapshot, or `nil` when nothing was written.
    ///
    /// The sequence is fixed: **list, ask, write, rename, prune.** The listing is
    /// what supplies the newest revision's hash, so dedup — by far the most common
    /// outcome on an aggressive autosave — costs one directory read and no content
    /// read at all. `now` is passed in rather than read so the whole engine stays a
    /// function of its inputs.
    ///
    /// Pruning runs here, on the one file just captured, because that is the file
    /// whose revision count just changed; the store-wide sweep
    /// (`pruneAll(now:)`) is for everything else. It prunes the list it already
    /// has in hand rather than re-reading the directory it just wrote to.
    @discardableResult
    public nonisolated func capture(
        text: String,
        root: URL,
        relativePath: String,
        event: LocalHistoryEvent,
        now: Date = Date()
    ) -> LocalHistorySnapshot? {
        let directory = layout.fileDirectory(forRoot: root, relativePath: relativePath)
        let existing = LocalHistorySnapshot.sortedNewestFirst(snapshots(in: directory))
        let decision = policy.capture(of: text, relativePath: relativePath, latestHash: existing.first?.contentHash)
        guard let hash = decision.hash else { return nil }

        let fileName = LocalHistoryLayout.snapshotFileName(timestamp: now, event: event, contentHash: hash)
        // Parsed back rather than assembled, so what this returns is exactly what
        // a listing of the directory will report — including the millisecond the
        // name rounded the timestamp to — and a name this version could not read
        // back is never written in the first place.
        guard let snapshot = LocalHistoryLayout.snapshot(fromFileName: fileName) else { return nil }

        let temporary = directory.appendingPathComponent(fileName + Self.temporarySuffix)
        var written = false
        // Two attempts, and the second one is not optimism about a failing disk:
        // the quit-time capture runs on the main thread while the store-wide sweep
        // may be running on the model's queue, and the sweep reclaims a file
        // directory it finds holding nothing (`prune(directory:now:)`) — which is
        // exactly what the `ensureDirectory` just above created. Losing the last
        // save before a quit to that window would lose the one edit the
        // synchronous path exists to guarantee, so the whole create-write-rename
        // is simply re-run once, which re-creates the directory the sweep took.
        for _ in 0..<2 {
            do {
                try fileService.ensureDirectory(at: directory)
                try fileService.write(text, to: temporary)
                try fileService.move(from: temporary, to: directory.appendingPathComponent(fileName))
                written = true
                break
            } catch {
                // Whatever the failure was, the temporary is removed if it got as
                // far as existing — so a retry starts from the same clean state
                // the first attempt did, and a second failure leaves nothing
                // behind either.
                discard(temporary)
            }
        }
        // Both attempts failed: the revision is lost and nothing else is, and the
        // caller is told `nil` rather than interrupted.
        guard written else { return nil }

        delete(policy.prune(existing + [snapshot], now: now).delete, in: directory)
        return snapshot
    }

    // MARK: - Retention

    /// Apply retention to **every** project area in the store — the
    /// once-per-folder-open sweep.
    ///
    /// Capture prunes the file it just wrote; this is what reclaims everything
    /// *else*, including the history of files that have not been touched since
    /// their revisions aged out.
    ///
    /// **Store-wide rather than per-project, and that is load-bearing.** Retention
    /// is what bounds a store that lives outside every project, and a sweep keyed
    /// to whichever root is being opened bounds nothing at all for a project
    /// cloned, edited once and never opened again: its whole history would sit
    /// there for the life of the machine. The store is one directory outside
    /// every project, so its housekeeping is asked of the directory, not of a
    /// root that happens to be in hand.
    ///
    /// **What this cannot reclaim, by design:** `LocalHistoryPolicy`'s third rule
    /// reinstates the newest revision of a file unconditionally, so a sweep takes
    /// every path ever captured down to one revision and no further — including a
    /// path whose file was since renamed, moved or deleted, which no window can
    /// reach again. That is the guarantee ("the revision from before that edit
    /// survives however old it is") paid for in bytes, and it is why the retention
    /// numbers are stated to the user with the newest-survives rule beside them
    /// rather than as an unconditional reclamation. Deleting the store directory
    /// is the only thing that removes everything.
    ///
    /// The cost is one directory read per project area on top of the per-file
    /// reads the sweep already did, on the capture chain's queue, once per open.
    public nonisolated func pruneAll(now: Date = Date()) {
        guard let entries = try? fileService.contentsOfDirectory(at: layout.base) else { return }
        for entry in entries where entry.isDirectory {
            prune(project: layout.base.appendingPathComponent(entry.name, isDirectory: true), now: now)
        }
    }

    /// Apply retention to one project's area alone. The unit `pruneAll(now:)` is
    /// made of, kept public because it is the smallest thing this rule can be
    /// stated and tested against.
    public nonisolated func prune(root: URL, now: Date = Date()) {
        prune(project: layout.projectDirectory(forRoot: root), now: now)
    }

    // MARK: - Private

    /// One project area: retention over each file directory, then the area itself
    /// if nothing is left in it.
    ///
    /// A file directory left with no entries at all is removed, so the store the
    /// user is invited to inspect in Finder does not accumulate a fan of empty
    /// directories, and an area left with no file directories goes the same way.
    /// Retention alone never empties a directory that holds a real snapshot — the
    /// newest one always survives (`pruneAll(now:)` states why) — so in practice
    /// these two branches reclaim a directory holding nothing but the `.partial`
    /// debris removed just above, or one this feature created and never wrote to.
    /// A directory still holding something foreign is left exactly as it is,
    /// because this feature deletes only what it wrote.
    private nonisolated func prune(project: URL, now: Date) {
        guard let entries = try? fileService.contentsOfDirectory(at: project) else { return }
        for entry in entries where entry.isDirectory {
            // Re-derived from the layout, never taken from the listing: see
            // `revisions(root:relativePath:)`.
            prune(directory: project.appendingPathComponent(entry.name, isDirectory: true), now: now)
        }
        // Re-listed rather than reasoned about: what the loop above removed is the
        // subset of `entries` that pruned empty, and re-deriving that here would be
        // a second copy of the emptiness rule.
        if let remaining = try? fileService.contentsOfDirectory(at: project), remaining.isEmpty {
            discard(project)
        }
    }

    private nonisolated func prune(directory: URL, now: Date) {
        guard let entries = try? fileService.contentsOfDirectory(at: directory) else { return }

        // Debris from an interrupted write, and the sweep is the only thing that
        // can reclaim it: listing and retention both look straight through a
        // `.partial` (that is what the suffix is *for*), so an unreclaimed one
        // would sit here for the life of the store and keep its directory from
        // ever counting as empty. Only names this feature could itself have
        // written are removed — a snapshot name plus our own suffix — so a
        // foreign file that happens to end in `.partial` is left where it is,
        // like every other foreign entry.
        let leftovers = entries.filter { !$0.isDirectory && Self.isInterruptedWrite($0.name) }
        for leftover in leftovers {
            discard(directory.appendingPathComponent(leftover.name))
        }

        if entries.count == leftovers.count {
            discard(directory)
            return
        }
        let stored = entries.compactMap { entry -> LocalHistorySnapshot? in
            entry.isDirectory ? nil : LocalHistoryLayout.snapshot(fromFileName: entry.name)
        }
        delete(policy.prune(stored, now: now).delete, in: directory)
    }

    /// Whether `name` is one of this feature's own half-written snapshots.
    static func isInterruptedWrite(_ name: String) -> Bool {
        guard name.hasSuffix(temporarySuffix) else { return false }
        return LocalHistoryLayout.snapshot(fromFileName: String(name.dropLast(temporarySuffix.count))) != nil
    }

    private nonisolated func snapshots(in directory: URL) -> [LocalHistorySnapshot] {
        guard let entries = try? fileService.contentsOfDirectory(at: directory) else { return [] }
        return entries.compactMap { entry -> LocalHistorySnapshot? in
            entry.isDirectory ? nil : LocalHistoryLayout.snapshot(fromFileName: entry.name)
        }
    }

    private nonisolated func delete(_ snapshots: [LocalHistorySnapshot], in directory: URL) {
        for snapshot in snapshots {
            discard(directory.appendingPathComponent(snapshot.fileName))
        }
    }

    /// Remove one path, if it is one of ours. The containment check is the same
    /// assertion `LSPInstallEngine` makes before every delete: a layout bug or a
    /// caller passing a url from somewhere else must not turn into `rm` on a
    /// user's file.
    private nonisolated func discard(_ url: URL) {
        guard layout.contains(url) else { return }
        try? fileService.removeItem(at: url)
    }
}
