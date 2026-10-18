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
/// **Each file directory also holds its path record and its label sidecars**
/// (`LocalHistoryLayout` spells both). Capture writes the record only when the
/// listing it already holds shows none and never reads one back; every reader
/// verifies a record before trusting it, so a wrong one makes its directory
/// record-less rather than misleading anything.
///
/// **Each project area also holds its activity record** — the local days on
/// which the project captured anything, which is what retention counts instead
/// of calendar days (`LocalHistoryPolicy.prune(_:now:activityDays:calendar:)`).
/// A capture that writes a revision reads it once and rewrites it only when
/// today is not already in it, so it is written at most once per day; a project
/// prune reads it once for every file directory in the area. It is read through
/// `fileService.read` alone, never by listing, so a capture-time prune still
/// lists nothing but its own file directory. `calendar` is injected so the
/// tests decide where midnight falls. The record is written only from inside
/// `capture`, so the quit path's synchronous capture writing it on the main
/// thread is that path's existing exception and not a new main-thread writer.
///
/// **A writer only of its own directory.** Every path this deletes is asserted
/// to be inside `layout.base` first; nothing here touches the user's files, so
/// it takes no `autosave.suspend()` / `localChanges.beginRevert()` gate and is
/// not gated by one.
public struct LocalHistoryStore {
    public let layout: LocalHistoryLayout
    public let policy: LocalHistoryPolicy
    public let calendar: Calendar
    private let fileService: FileServicing

    public init(
        layout: LocalHistoryLayout,
        fileService: FileServicing,
        policy: LocalHistoryPolicy = LocalHistoryPolicy(),
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.layout = layout
        self.fileService = fileService
        self.policy = policy
        self.calendar = calendar
    }

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
        return LocalHistorySnapshot.sortedNewestFirst(Self.snapshots(in: listing(of: directory)))
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

    /// The project-relative path of every file under `root` whose history
    /// carries a verified path record, sorted.
    ///
    /// **One directory read of the project area plus one record read per file
    /// directory** — the file directories themselves are not listed. A record
    /// that is absent or fails verification makes its directory record-less and
    /// it is skipped: that history stays readable forwards, by path, but nothing
    /// lists it. An unreadable area is `[]`.
    public nonisolated func recordedPaths(root: URL) -> [String] {
        let project = layout.projectDirectory(forRoot: root)
        guard let entries = try? fileService.contentsOfDirectory(at: project) else { return [] }
        return entries.compactMap { entry -> String? in
            guard entry.isDirectory else { return nil }
            // Re-derived from the layout, never taken from the listing: see
            // `revisions(root:relativePath:)`.
            let record = project
                .appendingPathComponent(entry.name, isDirectory: true)
                .appendingPathComponent(LocalHistoryLayout.pathRecordName)
            guard let text = try? fileService.read(url: record) else { return nil }
            return LocalHistoryLayout.relativePath(fromPathRecord: text, fileDirectoryName: entry.name)
        }
        .sorted()
    }

    /// Whether `relativePath` is no longer on disk under `root` — the one
    /// "missing on disk" question, asked by the deleted-file listing and by a
    /// restore deciding whether it recreates the file, so this store stays the
    /// only Local History type that asks the file service anything.
    public nonisolated func isMissing(root: URL, relativePath: String) -> Bool {
        let url = root.appendingPathComponent(LocalHistoryLayout.normalisedRelativePath(relativePath))
        return fileService.fileStamp(at: url) == nil
    }

    /// The user's label for one `.label` revision, or `nil` — no sidecar, an
    /// unreadable one, or text `LocalHistoryPolicy.label(from:)` refuses, every
    /// one of which displays as the plain event title. Any other event answers
    /// `nil` without a read, since only a labelled capture writes a sidecar.
    public nonisolated func labelText(
        of snapshot: LocalHistorySnapshot,
        root: URL,
        relativePath: String
    ) -> String? {
        guard snapshot.event == .label else { return nil }
        let directory = layout.fileDirectory(forRoot: root, relativePath: relativePath)
        let sidecar = directory.appendingPathComponent(
            LocalHistoryLayout.labelFileName(forSnapshotFileName: snapshot.fileName)
        )
        return (try? fileService.read(url: sidecar)).flatMap(LocalHistoryPolicy.label(from:))
    }

    // MARK: - Capturing

    /// Store `text` as the next revision of `relativePath`, unless the policy says
    /// otherwise; the stored snapshot, or `nil` when nothing was written.
    ///
    /// The sequence is fixed: **list, ask, write, rename, record, note the day,
    /// prune.** The
    /// listing is what supplies the newest revision's hash, so dedup — by far the
    /// most common outcome on an aggressive autosave — costs one directory read
    /// and no content read at all. `now` is passed in rather than read so the
    /// whole engine stays a function of its inputs.
    ///
    /// **The path record is driven by that same listing.** When the directory
    /// holds a snapshot — already, or after this write — and the listing shows no
    /// `path` entry, the record is written; a dedup'd capture into a directory
    /// written before records existed is therefore what gives it one. A present
    /// record is never read and never rewritten, correct or not: verification is
    /// the readers' job (`LocalHistoryLayout.relativePath(fromPathRecord:
    /// fileDirectoryName:)`), and only a migration corrects a wrong one.
    ///
    /// `label` is used only with `.label`, and only as far as `LocalHistoryPolicy
    /// .label(from:)` accepts it — the same function the reader asks, so no text
    /// it would refuse ever reaches the disk. Its sidecar is written **before**
    /// the snapshot, so a listing never shows the row ahead of its text, and a
    /// sidecar that cannot be written loses the revision rather than leaving a
    /// labelled capture without its label. A snapshot write that fails after the
    /// sidecar landed leaves an orphan the sweep reclaims.
    ///
    /// Pruning runs here, on the one file just captured, because that is the file
    /// whose revision count just changed; the store-wide sweep
    /// (`pruneAll(now:)`) is for everything else. It prunes the list it already
    /// has in hand rather than re-reading the directory it just wrote to, against
    /// the activity days the noting step just read (and, once a day, wrote).
    /// Only a written revision notes the day: a skipped capture changes nothing in
    /// the store, so it neither creates an area for the record nor counts as a
    /// day this project's history moved.
    @discardableResult
    public nonisolated func capture(
        text: String,
        root: URL,
        relativePath: String,
        event: LocalHistoryEvent,
        label: String? = nil,
        now: Date = Date()
    ) -> LocalHistorySnapshot? {
        let directory = layout.fileDirectory(forRoot: root, relativePath: relativePath)
        let entries = listing(of: directory)
        let existing = LocalHistorySnapshot.sortedNewestFirst(Self.snapshots(in: entries))
        let hasRecord = entries.contains { $0.name == LocalHistoryLayout.pathRecordName }
        let decision = policy.capture(
            of: text,
            relativePath: relativePath,
            latestHash: existing.first?.contentHash,
            event: event
        )
        guard let hash = decision.hash else {
            if !existing.isEmpty, !hasRecord { writeRecord(relativePath, in: directory) }
            return nil
        }

        let fileName = LocalHistoryLayout.snapshotFileName(timestamp: now, event: event, contentHash: hash)
        // Parsed back rather than assembled, so what this returns is exactly what
        // a listing of the directory will report — including the millisecond the
        // name rounded the timestamp to — and a name this version could not read
        // back is never written in the first place.
        guard let snapshot = LocalHistoryLayout.snapshot(fromFileName: fileName) else { return nil }

        if event == .label, let text = label.flatMap(LocalHistoryPolicy.label(from:)) {
            let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: fileName)
            guard writeInPlace(text, named: sidecar, in: directory) else { return nil }
        }
        // Both attempts failed: the revision is lost and nothing else is, and the
        // caller is told `nil` rather than interrupted.
        guard writeInPlace(text, named: fileName, in: directory) else { return nil }
        if !hasRecord { writeRecord(relativePath, in: directory) }

        let days = noteActivity(root: root, now: now)
        delete(prunable(existing + [snapshot], now: now, activityDays: days), in: directory)
        return snapshot
    }

    // MARK: - Migrating

    /// Carry the history of `oldPath` to `newPath` — the rename or move of one
    /// file, or of a folder and every file under it.
    ///
    /// **Records only, for files and folders alike.** The affected set is every
    /// verified record (`recordedPaths(root:)`) equal to `oldPath` or under it at
    /// a `/` boundary, so `a` never takes `ab/x` with it; both sides are compared
    /// in `LocalHistoryLayout.normalisedRelativePath`'s spelling, the one the
    /// records are written in. A directory without a verified record does not
    /// move: a file never captured since records existed keeps its history under
    /// the old key, readable forwards and reached by nothing else.
    ///
    /// Each affected directory is carried on its own and fails silently on its
    /// own (`migrate(_:to:root:now:)`), so one stuck directory strands one file's
    /// history and nothing more. The set is read once, before anything moves, so a
    /// directory this call has just re-keyed is never visited twice.
    public nonisolated func migrate(root: URL, from oldPath: String, to newPath: String, now: Date = Date()) {
        let old = LocalHistoryLayout.normalisedRelativePath(oldPath)
        let new = LocalHistoryLayout.normalisedRelativePath(newPath)
        guard !old.isEmpty, !new.isEmpty, old != new else { return }
        for recorded in recordedPaths(root: root) {
            guard let moved = Self.rekeyed(recorded, from: old, to: new) else { continue }
            migrate(recorded, to: moved, root: root, now: now)
        }
    }

    /// `path` re-keyed from under `old` to under `new`, or `nil` when it is
    /// neither `old` itself nor below it at a component boundary.
    static func rekeyed(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        guard path.hasPrefix(old + "/") else { return nil }
        return new + path.dropFirst(old.count)
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
    /// these two branches reclaim a directory holding nothing but debris — a
    /// `.partial`, an orphan label sidecar, a path record with no revision beside
    /// it — or one this feature created and never wrote to.
    /// A directory still holding something foreign is left exactly as it is,
    /// because this feature deletes only what it wrote.
    ///
    /// The activity record is read once, before the loop, and every file
    /// directory is judged against that one answer. It is the area's own
    /// bookkeeping rather than a history, so it does not keep an otherwise empty
    /// area alive: an area holding nothing but the record loses it and then
    /// itself. Anything else at the area's top level is foreign and keeps the
    /// area where it is.
    private nonisolated func prune(project: URL, now: Date) {
        guard let entries = try? fileService.contentsOfDirectory(at: project) else { return }
        let days = activityDays(inProject: project)
        for entry in entries where entry.isDirectory {
            // Re-derived from the layout, never taken from the listing: see
            // `revisions(root:relativePath:)`.
            prune(directory: project.appendingPathComponent(entry.name, isDirectory: true), now: now, activityDays: days)
        }
        // Re-listed rather than reasoned about: what the loop above removed is the
        // subset of `entries` that pruned empty, and re-deriving that here would be
        // a second copy of the emptiness rule.
        guard let remaining = try? fileService.contentsOfDirectory(at: project) else { return }
        guard remaining.allSatisfy({ !$0.isDirectory && $0.name == LocalHistoryLayout.activityRecordName })
        else { return }
        if !remaining.isEmpty {
            discard(project.appendingPathComponent(LocalHistoryLayout.activityRecordName))
        }
        // Re-listed once more before the recursive removal, for the reason
        // `prune(directory:now:activityDays:)` gives: the quit capture bypasses the
        // chain and can land a whole file directory here meanwhile.
        if let relisted = try? fileService.contentsOfDirectory(at: project), relisted.isEmpty {
            discard(project)
        }
    }

    private nonisolated func prune(directory: URL, now: Date, activityDays: [String]?) {
        guard let entries = try? fileService.contentsOfDirectory(at: directory) else { return }
        let files = entries.filter { !$0.isDirectory }.map(\.name)
        let snapshotNames = Set(Self.snapshots(in: entries).map(\.fileName))

        // Debris from an interrupted write, and the sweep is the only thing that
        // can reclaim it: listing and retention both look straight through a
        // `.partial` (that is what the suffix is *for*), so an unreclaimed one
        // would sit here for the life of the store and keep its directory from
        // ever counting as empty. Only names this feature could itself have
        // written are removed (`LocalHistoryLayout.isOwnTemporary`), so a foreign
        // file that happens to end in `.partial` is left where it is, like every
        // other foreign entry. A label sidecar whose snapshot is not in the
        // listing is debris too — a snapshot write that failed after its sidecar
        // landed — and nothing but the sweep would ever see it.
        let leftovers = files.filter { name in
            if LocalHistoryLayout.isOwnTemporary(name) { return true }
            guard let owner = LocalHistoryLayout.snapshotFileName(fromLabelFileName: name) else { return false }
            return !snapshotNames.contains(owner)
        }
        for leftover in leftovers {
            discard(directory.appendingPathComponent(leftover))
        }

        // Empty means no snapshot and nothing foreign: what is left is the path
        // record or nothing at all. A record with no revision beside it describes
        // no history, so it goes first and the directory after it.
        let remaining = Set(entries.map(\.name)).subtracting(leftovers)
        let recordOnly = remaining.isEmpty
            || (remaining == [LocalHistoryLayout.pathRecordName] && files.contains(LocalHistoryLayout.pathRecordName))
        if recordOnly {
            if !remaining.isEmpty {
                discard(directory.appendingPathComponent(LocalHistoryLayout.pathRecordName))
            }
            // Re-listed rather than decided on the listing above, and that is not
            // tidiness: `discard` is recursive, and the synchronous quit capture
            // bypasses the chain, so it can land a whole snapshot in this
            // directory while the entries above are being removed. Removing on
            // the stale listing would take that snapshot with the directory —
            // silently, and past any help from `capture`'s retry, which has
            // already seen its `move` succeed and broken out of the loop. The
            // edit at stake is the last save before a quit, which is the one the
            // synchronous path exists to guarantee. Such a capture may find the
            // record still listed and not write one; the next capture's listing
            // shows it gone and writes it then. What is left is the ordinary
            // window between this listing and the removal below, which is the
            // same residual every other reclamation here accepts.
            if let relisted = try? fileService.contentsOfDirectory(at: directory), relisted.isEmpty {
                discard(directory)
            }
            return
        }
        delete(prunable(Self.snapshots(in: entries), now: now, activityDays: activityDays), in: directory)
    }

    /// Retention's condemned revisions, asked of the policy with this store's
    /// calendar — the one spelling of that call, shared by capture, the sweep and
    /// a merge.
    private nonisolated func prunable(
        _ snapshots: [LocalHistorySnapshot],
        now: Date,
        activityDays: [String]?
    ) -> [LocalHistorySnapshot] {
        policy.prune(snapshots, now: now, activityDays: activityDays, calendar: calendar).delete
    }

    /// The activity days `project`'s record holds, or `nil` when there is no
    /// record or it does not parse — which retention reads as "the calendar rule
    /// alone". One read, no listing.
    private nonisolated func activityDays(inProject project: URL) -> [String]? {
        let record = project.appendingPathComponent(LocalHistoryLayout.activityRecordName)
        return (try? fileService.read(url: record)).flatMap(LocalHistoryLayout.activityDays(fromRecord:))
    }

    /// Add `now`'s local day to `root`'s activity record unless it is already
    /// there, and answer the days the record now holds.
    ///
    /// One read always; a write only when the day is new, so the record is
    /// written at most once per day per project.
    ///
    /// **Written in place, not through `writeInPlace`**, because unlike every
    /// other file here the record is *replaced*, and a `move` refuses an existing
    /// destination. `FileServicing.write` is itself atomic on the real service
    /// (a temporary of its own and one rename over the old record), so a reader
    /// sees the old days or the new ones and never a missing or half-written
    /// record — which removing the old record first would have exposed to a
    /// concurrent sweep as "no record, calendar rule". "Already there" rather than
    /// "already the newest" is what keeps a clock set backwards from rewriting it
    /// on every capture. A garbled record is replaced by one holding today alone
    /// — retention only ever grows more lenient for it, never less. A write that
    /// fails is silent and answers what was read, so the prune that follows
    /// judges by what is actually on disk.
    private nonisolated func noteActivity(root: URL, now: Date) -> [String]? {
        let project = layout.projectDirectory(forRoot: root)
        let recorded = activityDays(inProject: project)
        let today = LocalHistoryLayout.activityDay(of: now, calendar: calendar)
        if let recorded, recorded.contains(today) { return recorded }
        let updated = LocalHistoryLayout.normalizedActivityDays((recorded ?? []) + [today])
        let text = LocalHistoryLayout.activityRecordText(days: updated)
        do {
            try fileService.ensureDirectory(at: project)
            try fileService.write(text, to: project.appendingPathComponent(LocalHistoryLayout.activityRecordName))
            return updated
        } catch {
            return recorded
        }
    }

    /// One directory's entries, or none when it cannot be read — which for a
    /// file directory is the common case of a file with no history yet.
    private nonisolated func listing(of directory: URL) -> [DirectoryEntry] {
        (try? fileService.contentsOfDirectory(at: directory)) ?? []
    }

    private static func snapshots(in entries: [DirectoryEntry]) -> [LocalHistorySnapshot] {
        entries.compactMap { entry -> LocalHistorySnapshot? in
            entry.isDirectory ? nil : LocalHistoryLayout.snapshot(fromFileName: entry.name)
        }
    }

    /// Write `text` under `name` in `directory` atomically: a temporary first,
    /// then one `move` into place; whether it landed.
    ///
    /// Two attempts, and the second one is not optimism about a failing disk:
    /// the quit-time capture runs on the main thread while the store-wide sweep
    /// may be running on the model's queue, and the sweep reclaims a file
    /// directory it finds holding nothing (`prune(directory:now:activityDays:)`) — which is
    /// exactly what the `ensureDirectory` here created. Losing the last save
    /// before a quit to that window would lose the one edit the synchronous path
    /// exists to guarantee, so the whole create-write-rename is simply re-run
    /// once, which re-creates the directory the sweep took. The mirror ordering —
    /// the sweep reclaiming the directory *after* the `move` has landed — is out
    /// of reach from here, since by then this loop has already returned;
    /// `prune(directory:now:activityDays:)` answers that one by re-listing immediately before
    /// it removes. Snapshots, sidecars and records all go through here, so they
    /// share the one discipline.
    private nonisolated func writeInPlace(_ text: String, named name: String, in directory: URL) -> Bool {
        let destination = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(name + LocalHistoryLayout.temporarySuffix)
        for _ in 0..<2 {
            do {
                try fileService.ensureDirectory(at: directory)
                try fileService.write(text, to: temporary)
                try fileService.move(from: temporary, to: destination)
                return true
            } catch {
                // Whatever the failure was, the temporary is removed if it got as
                // far as existing — so a retry starts from the same clean state
                // the first attempt did, and a second failure leaves nothing
                // behind either.
                discard(temporary)
            }
        }
        return false
    }

    /// The path record for `relativePath`, written in place. Failure is silent:
    /// the directory stays record-less, readable forwards, and the next capture's
    /// listing shows no record and tries again.
    private nonisolated func writeRecord(_ relativePath: String, in directory: URL) {
        _ = writeInPlace(
            LocalHistoryLayout.pathRecordText(forRelativePath: relativePath),
            named: LocalHistoryLayout.pathRecordName,
            in: directory
        )
    }

    /// One file directory carried from `oldPath`'s key to `newPath`'s.
    ///
    /// **One directory `move`, then the record.** The moved record still names
    /// the old path, so it is replaced; a crash between the two leaves a wrong
    /// record, which every reader already treats as none — readable forwards
    /// under the new key, listed by nothing — and the next capture's listing
    /// still shows a `path` entry, so only another migration corrects it.
    ///
    /// The `move` refuses an existing destination, which in practice is what a
    /// failure means: the new path already has a history of its own (a file
    /// moved over one that was deleted, a folder moved onto a folder). That falls
    /// back to `merge(_:into:relativePath:now:activityDays:)`.
    ///
    /// **A destination holding nothing is not a history, and not a reason to
    /// stay behind either.** An empty directory is what a capture that failed
    /// after its `ensureDirectory` leaves, and refusing it would strand the
    /// source under the old key for good, since nothing migrates it again. So it
    /// is merged into like any other — entry by entry, and never removed: only
    /// a listing that *succeeded* says what a destination holds, so one that
    /// cannot be listed at all (absent, a file, unreadable) leaves the source
    /// exactly where it was and the destination untouched.
    private nonisolated func migrate(_ oldPath: String, to newPath: String, root: URL, now: Date) {
        let source = layout.fileDirectory(forRoot: root, relativePath: oldPath)
        let destination = layout.fileDirectory(forRoot: root, relativePath: newPath)
        if (try? fileService.move(from: source, to: destination)) != nil {
            replaceRecord(with: newPath, in: destination)
            return
        }
        let days = activityDays(inProject: layout.projectDirectory(forRoot: root))
        merge(source, into: destination, relativePath: newPath, now: now, activityDays: days)
    }

    /// Carry `source`'s revisions into the existing `destination` entry by
    /// entry: the two histories become one list, pruned as one.
    ///
    /// - **A name on both sides keeps the destination's copy** and discards the
    ///   source's. A snapshot name is its timestamp, event and content hash, so
    ///   the two copies are the same revision; a sidecar follows its snapshot.
    ///   A source copy that cannot be removed counts as an entry that did not
    ///   move: it strands, with its sidecar and its record.
    /// - **A labelled snapshot and its sidecar move as a pair**, sidecar first —
    ///   the order a capture writes them in, so the destination never lists a
    ///   labelled row ahead of its text. The sidecar goes ahead as a *copy*, and
    ///   the source's original is removed only once the snapshot has moved: a
    ///   sidecar that cannot be copied keeps its snapshot at the source with it,
    ///   and a snapshot that cannot move has the copy discarded — a discard that
    ///   fails leaves only a spare orphan the sweep reclaims, never the one label
    ///   on the wrong side of its snapshot. A sidecar whose snapshot the source
    ///   does not hold is carried on its own, as before: the destination may hold
    ///   that snapshot.
    /// - **Only what this feature wrote is carried.** Its own temporaries are
    ///   debris and are discarded; a foreign entry stays where it is, and so then
    ///   do the source's record and directory, because a directory still holding
    ///   something is not this feature's to remove. An entry whose `move` fails
    ///   is left the same way, under a record that still names it.
    /// - **The destination's record is made correct**, which also corrects a
    ///   wrong one, and the merged list is pruned by the ordinary per-file rule,
    ///   label sidecars going with their snapshots.
    private nonisolated func merge(
        _ source: URL,
        into destination: URL,
        relativePath: String,
        now: Date,
        activityDays: [String]?
    ) {
        // A destination that cannot be listed is no directory to merge into —
        // absent, a file, or unreadable — and is left exactly as it is. An empty
        // listing is a real answer, and is merged into like any other.
        guard let incoming = try? fileService.contentsOfDirectory(at: source),
              let present = try? fileService.contentsOfDirectory(at: destination)
        else { return }
        let taken = Set(present.map(\.name))
        let files = incoming.filter { !$0.isDirectory }.map(\.name)
        let sidecars = files.filter { LocalHistoryLayout.snapshotFileName(fromLabelFileName: $0) != nil }
        let snapshots = files.filter { LocalHistoryLayout.snapshot(fromFileName: $0) != nil }
        let sidecarSet = Set(sidecars)

        var stranded = incoming.contains { $0.isDirectory }
        func carry(_ name: String) -> Bool {
            let from = source.appendingPathComponent(name)
            // A duplicate counts as carried only once it is gone: one that
            // cannot be removed is still a revision here, and strands like a
            // failed move, keeping its sidecar and the record that names it.
            if taken.contains(name) { return removed(from) }
            return (try? fileService.move(from: from, to: destination.appendingPathComponent(name))) != nil
        }
        // A sidecar goes ahead of its snapshot as a *copy*, so the source keeps
        // the original until the snapshot has landed: no failure at any step —
        // the copy, the snapshot's move, the cleanup of either — can leave the
        // snapshot on one side and its only label on the other.
        func copySidecar(_ name: String) -> Bool {
            guard let text = try? fileService.read(url: source.appendingPathComponent(name)) else { return false }
            return writeInPlace(text, named: name, in: destination)
        }
        for name in snapshots {
            let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: name)
            let paired = sidecarSet.contains(sidecar)
            // A sidecar the destination already holds is not copied, and the
            // source's is discarded only once its snapshot has gone, so a
            // snapshot that stays keeps its own.
            let sidecarCopied = paired && !taken.contains(sidecar)
            if sidecarCopied, !copySidecar(sidecar) {
                stranded = true
                continue
            }
            if carry(name) {
                if paired { discard(source.appendingPathComponent(sidecar)) }
            } else {
                stranded = true
                if sidecarCopied { discard(destination.appendingPathComponent(sidecar)) }
            }
        }
        let snapshotSet = Set(snapshots)
        for name in sidecars {
            guard let owner = LocalHistoryLayout.snapshotFileName(fromLabelFileName: name),
                  !snapshotSet.contains(owner) else { continue }
            if !carry(name) { stranded = true }
        }
        for name in files where !sidecars.contains(name) && !snapshots.contains(name) {
            if LocalHistoryLayout.isOwnTemporary(name) {
                discard(source.appendingPathComponent(name))
            } else if name != LocalHistoryLayout.pathRecordName {
                stranded = true
            }
        }
        if !stranded {
            discard(source.appendingPathComponent(LocalHistoryLayout.pathRecordName))
            // Re-listed rather than decided on the listing above, as in
            // `prune(directory:now:activityDays:)`: a quit-time capture bypasses the chain.
            if let relisted = try? fileService.contentsOfDirectory(at: source), relisted.isEmpty {
                discard(source)
            }
        }

        replaceRecord(with: relativePath, in: destination)
        delete(
            prunable(Self.snapshots(in: listing(of: destination)), now: now, activityDays: activityDays),
            in: destination
        )
    }

    /// Make `directory`'s record name `relativePath`: left alone when it already
    /// verifies as exactly that, otherwise removed and written afresh — removed
    /// first, because a `move` into place refuses an existing destination.
    private nonisolated func replaceRecord(with relativePath: String, in directory: URL) {
        let record = directory.appendingPathComponent(LocalHistoryLayout.pathRecordName)
        let current = (try? fileService.read(url: record)).flatMap {
            LocalHistoryLayout.relativePath(fromPathRecord: $0, fileDirectoryName: directory.lastPathComponent)
        }
        guard current != LocalHistoryLayout.normalisedRelativePath(relativePath) else { return }
        discard(record)
        writeRecord(relativePath, in: directory)
    }

    /// Delete retention's condemned revisions, each `.label` one with its sidecar
    /// — a label has no meaning once the revision it names is gone.
    private nonisolated func delete(_ snapshots: [LocalHistorySnapshot], in directory: URL) {
        for snapshot in snapshots {
            discard(directory.appendingPathComponent(snapshot.fileName))
            if snapshot.event == .label {
                discard(directory.appendingPathComponent(
                    LocalHistoryLayout.labelFileName(forSnapshotFileName: snapshot.fileName)
                ))
            }
        }
    }

    /// Remove one path, if it is one of ours. The containment check is the same
    /// assertion `LSPInstallEngine` makes before every delete: a layout bug or a
    /// caller passing a url from somewhere else must not turn into `rm` on a
    /// user's file.
    private nonisolated func discard(_ url: URL) {
        _ = removed(url)
    }

    /// `discard(_:)` for the one caller that must know it worked: whether `url`
    /// is gone — `false` for a removal that failed and for a url that is not
    /// ours, which is never removed.
    private nonisolated func removed(_ url: URL) -> Bool {
        guard layout.contains(url) else { return false }
        return (try? fileService.removeItem(at: url)) != nil
    }
}
