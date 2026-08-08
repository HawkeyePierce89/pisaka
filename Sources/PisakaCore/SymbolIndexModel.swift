import Foundation

/// Observable state for the project-wide **symbol index**: the traversal of the
/// opened folder, the extraction of every file worth indexing, and the bookkeeping
/// that keeps the index honest while the project changes under it.
///
/// Modelled directly on `ProjectSearchModel` — an `@MainActor ObservableObject`
/// whose I/O is injected behind `FileServicing`, whose branching decisions are
/// pure `nonisolated static` helpers, whose off-main work runs on a private
/// serial queue, and whose overlapping operations are ordered by a generation
/// token captured **synchronously** (`prepareForFolderChange`) before any `Task`
/// hop. It walks the project through the very same
/// `ProjectFileWalk.collectFiles`, so a file Find in Files declines to read is
/// invisible to go-to-definition too.
///
/// **This model is a reader.** It never writes to disk, never mutates a buffer,
/// and therefore never takes the autosave/revert gate that every git-mutating
/// operation raises. A refresh landing in the middle of a revert or a branch
/// switch is harmless: the worst case is that it indexes a file mid-rewrite and
/// the next refresh corrects it. Nothing here may grow a `beginRevert`/`suspend`
/// bracket — a reader that took the writer gate would serialize the editor
/// behind a background walk for no benefit.
///
/// **The extractor seam is synchronous, and there is no extractor actor.**
/// `extractSymbols` is a plain `@Sendable` function (the app layer's tree-sitter
/// bridge, which is the only reason Core stays Foundation-only) and it is
/// **never awaited**: it is called exclusively from inside this model's own
/// `offMain { … }` blocks, so the private serial queue is the single
/// serialization authority and the `offMain(whole chunk) → re-check generation`
/// shape `ProjectSearchModel` establishes is preserved exactly. An async closure
/// awaited *per file* would have to be lifted out of the chunk body, turning one
/// hop and one generation re-check per chunk into one of each per file, and
/// would add a second ordering authority on top of the queue. Thread safety is
/// the `MinimapTokenizer.computeModel` arrangement the app already relies on:
/// each call builds its own parser and cursor and only *reads* the shared,
/// lock-guarded grammar caches. Note the scope: this is the *indexing* seam. The
/// user-facing `CodeIntelligenceProviding` protocol stays async, and that is the
/// seam a phase-2 language server slots into.
///
/// **Buffer over disk.** A file whose text came from a live editor buffer is
/// marked buffer-sourced, and a disk-sourced chunk result never overwrites such
/// an entry. Without that rule a mid-walk edit would be clobbered moments later
/// by the file's stale on-disk text arriving in a chunk that had already read
/// it.
@MainActor
public final class SymbolIndexModel: ObservableObject {
    // The constants and the pure helpers are `nonisolated` because they are read
    // and called from outside the main actor (from inside `offMain`, and by the
    // `init` default arguments); without it they inherit the class's isolation
    // and every such reference is a Swift 6 error.

    /// How many files one off-main batch extracts before publishing. The same 32
    /// as project search, and for the same reason: small enough that the index
    /// becomes usable while the walk continues, large enough that the per-hop
    /// cost stays negligible next to the parses.
    public nonisolated static let chunkSize = 32

    /// The largest file the index will read (1 MiB) — `ProjectSearchModel`'s cap,
    /// shared so the two features agree about what "too big to be source" means.
    public nonisolated static let defaultMaxFileBytes = 1 << 20

    /// Languages the editor highlights but does **not** index, because they ship
    /// no `symbols.scm`: a gitignore file declares nothing a jump could land on.
    ///
    /// Held here rather than on `SyntaxLanguage` because it is a statement about
    /// the *query resources*, not about the language: Core cannot read the app
    /// bundle, so this is the one place the two are reconciled, and
    /// `SymbolQueryTests` asserts by set equality that the shipped
    /// `Resources/Queries` directory contains a query for every language *except*
    /// these. A language added to the enum therefore fails that suite until
    /// either its query exists or it is listed here — it can never silently
    /// index to nothing.
    public nonisolated static let unindexableLanguages: Set<SyntaxLanguage> = [.gitignore]

    /// Whether files of `language` are worth extracting symbols from.
    public nonisolated static func isIndexable(_ language: SyntaxLanguage) -> Bool {
        !unindexableLanguages.contains(language)
    }

    /// The indexable language of `fileName`, or `nil` when the file must be
    /// skipped — an unknown extension, or a language with no query.
    ///
    /// Applied by the traversal *before* any read, so an unindexable file costs
    /// one name lookup rather than a file read and a parse.
    public nonisolated static func indexableLanguage(forFileName fileName: String) -> SyntaxLanguage? {
        guard let language = SyntaxLanguage(forFileName: fileName), isIndexable(language) else {
            return nil
        }
        return language
    }

    /// The index as it currently stands — republished after **every chunk**, so
    /// the symbols of the files walked so far are answerable while the rest of
    /// the project is still being read.
    ///
    /// A value type, so `SymbolIntelligenceProvider` reads a coherent snapshot
    /// without a lock and never observes a half-applied chunk.
    @Published public private(set) var index = SymbolIndex()

    /// `true` from the moment a rebuild or refresh begins until it finishes or is
    /// superseded.
    @Published public private(set) var isIndexing = false

    private let fileService: FileServicing
    private let openBuffers: () -> [URL: String]
    private let extractSymbols: @Sendable (String, SyntaxLanguage, URL) -> [Symbol]
    private let maxFileBytes: Int

    /// Serial, so the traversal and every extraction batch run one after another
    /// off the main thread — and so the injected extractor (a tree-sitter parse,
    /// which is not safe to run concurrently over shared state) is never entered
    /// twice at once. See the type's note: this queue *is* the serialization.
    ///
    /// `.utility` rather than project search's `.userInitiated`: nobody is
    /// waiting on a screenful of results here, and a background index must not
    /// compete with the editor for cores while the user types.
    private let queue = DispatchQueue(label: "ws.karmanov.pisaka.symbol-index", qos: .utility)

    /// Monotonically increasing token identifying the latest indexing *request*.
    /// Bumped by `prepareForFolderChange`, `rebuild` and `refresh`; running work
    /// commits published state only while its captured token is still the latest.
    private var generation = 0

    /// Monotonically increasing token identifying the indexed **project**. Bumped
    /// only when the opened folder actually changes.
    ///
    /// Separate from `generation` because the two answer different questions. A
    /// walk uses `generation` to discard *its own* superseded results, and every
    /// rebuild and refresh advances it. A buffer re-index must only be discarded
    /// when the user has left the project — gating it on `generation` instead
    /// means an FSEvents refresh landing mid-parse (a save, a build, an `npm i`)
    /// throws away the very edits the user is typing, and nothing retries them
    /// until the next keystroke.
    private var rootGeneration = 0

    /// The folder last indexed or prepared for, so `prepareForFolderChange` can
    /// tell a genuine folder switch from a repeat call — and so `refresh` can
    /// tell a refresh from a folder change wearing its clothes.
    private var lastRoot: URL?

    /// The key of every file currently in the index.
    ///
    /// `SymbolIndex` is keyed by canonical path and does not hand its keys back;
    /// this is what lets a refresh compute "which indexed files did the walk stop
    /// seeing" as a set difference. Keys alone, no URLs: removal goes through
    /// `SymbolIndex.remove(fileKey:)` precisely so a vanished file's entry is not
    /// looked up by re-canonicalizing a path that no longer resolves.
    private var indexedFiles: Set<String> = []

    /// File key → the stamp the file had when it was last extracted **from
    /// disk**. A file with no entry here is always re-extracted, which is the
    /// safe direction: a stub service reporting no stamps degrades to
    /// correct-but-slower rather than to a stale index.
    private var stamps: [String: FileStamp] = [:]

    /// Files whose current entry was extracted from a **live editor buffer**.
    ///
    /// Two consequences, both load-bearing: a disk-sourced chunk never overwrites
    /// one of these (the buffer is ahead of the file), and a refresh neither
    /// re-extracts nor removes one (the buffer owns it until `forgetBuffer`).
    private var bufferSourced: Set<String> = []

    /// Files whose buffer was given up (`forgetBuffer`, i.e. a tab close) **since
    /// the current walk read its buffer snapshot**.
    ///
    /// The walk's counterpart to `reindexBuffer`'s post-parse cancellation check,
    /// and it exists for exactly the failure that check prevents. A chunk carries
    /// `.walkBuffer` outcomes for the tabs that were open when the walk started;
    /// if one of those tabs closes while the chunk is in flight, `forgetBuffer`
    /// runs first (clearing a mark that was never set) and `apply` lands
    /// afterwards, marking the file buffer-sourced with no editor behind it. The
    /// entry would then be frozen for the rest of the session: `extractChunk`
    /// skips buffer-sourced files, so no refresh re-reads it from disk, and
    /// `removeFiles` exempts them, so it would go on answering go-to-definition
    /// even after the file was deleted.
    ///
    /// `apply` therefore **drops** such an outcome outright rather than merely
    /// demoting it to `.disk`. Demoting fixes the ownership but not the text: a
    /// close also runs `reindexFromDisk`, and that hand-off can land *first* — the
    /// walk's chunk is already extracted and only waiting on the main actor, while
    /// the hand-off's one-file read is a much shorter trip — so a published
    /// `.walkBuffer` outcome would overwrite the correct disk symbols with the
    /// closed buffer's text. Nothing corrects that: a close writes nothing, so no
    /// watcher fires. Dropping is safe precisely because the close guarantees the
    /// hand-off (see `forgetBuffer`), which re-derives the entry from disk in
    /// whichever order the two land.
    ///
    /// Cleared at the start of every walk, so it only ever describes the window it
    /// is consulted for, and a stale key could at worst cost one extra disk
    /// extraction — the safe direction.
    private var buffersClosedDuringWalk: Set<String> = []

    /// - Parameters:
    ///   - openBuffers: the *unsaved* text of every open editor tab that has a
    ///     URL, keyed by that URL — `ProjectSearchModel`'s closure, and in the app
    ///     literally the same one. Called on the main actor, **once** per walk
    ///     before it starts, so the walk itself never touches the main thread per
    ///     file. A file with an open tab is indexed from that tab's text.
    ///   - extractSymbols: text + language + file URL → the symbols declared in
    ///     it. Synchronous by design (see the type's note on the seam), and
    ///     called only from inside this model's off-main blocks. Defaults to "no
    ///     symbols", so Core's own tests and any caller without a tree-sitter
    ///     layer get an index that is empty rather than absent.
    public init(
        fileService: FileServicing = FileService(),
        openBuffers: @escaping () -> [URL: String] = { [:] },
        extractSymbols: @escaping @Sendable (String, SyntaxLanguage, URL) -> [Symbol] = { _, _, _ in [] },
        maxFileBytes: Int = SymbolIndexModel.defaultMaxFileBytes
    ) {
        self.fileService = fileService
        self.openBuffers = openBuffers
        self.extractSymbols = extractSymbols
        self.maxFileBytes = maxFileBytes
    }

    /// The provider the editor surfaces ask their questions through, reading this
    /// model's latest published snapshot.
    ///
    /// Owned here so the app holds exactly one object: the model *is* the index's
    /// lifecycle, and a provider constructed separately would either capture a
    /// stale `SymbolIndex` value or duplicate the "which root are we in" state.
    /// The closures are `[weak self]`, so the provider can outlive a torn-down
    /// model and answer "nothing" instead of resurrecting it.
    public private(set) lazy var provider: SymbolIntelligenceProvider = SymbolIntelligenceProvider(
        index: { [weak self] in self?.index ?? SymbolIndex() },
        projectRoot: { [weak self] in self?.lastRoot }
    )

    // MARK: - Generation

    /// Synchronously record that the indexed project is switching to `root`
    /// (`nil` when the folder was closed), returning the request generation the
    /// switch produced.
    ///
    /// The `ProjectSearchModel.prepareForSearch` / `LocalChangesModel`
    /// precedent, and for the same reason: the app calls this in the same
    /// main-actor turn that handles the folder open, *before* spawning any
    /// `Task`, so an in-flight walk resumes to find itself superseded rather than
    /// publishing the previous project's symbols into the new one's editor. The
    /// index is cleared here too, so no stale symbol is jumpable to while the new
    /// project is being walked — a definition that opens a file from the folder
    /// the user just left is worse than no definition at all.
    ///
    /// A repeat call for the same folder is a no-op returning the current
    /// generation. No walk is spawned: the caller pins this token and calls
    /// `rebuild(root:request:)`.
    @discardableResult
    public func prepareForFolderChange(root: URL?) -> Int {
        guard root != lastRoot else { return generation }
        lastRoot = root
        generation += 1
        rootGeneration += 1
        clearIndex()
        isIndexing = false
        return generation
    }

    /// The current request generation, captured synchronously by a caller that
    /// defers a `rebuild`/`refresh` across a `Task` hop and passes it back as
    /// `request:`.
    public var currentRequestGeneration: Int { generation }

    // MARK: - Rebuild

    /// Walk `root` from scratch and extract every indexable file, publishing
    /// after each chunk.
    ///
    /// A `request` that a newer folder change has superseded is rejected before
    /// any work — the `LocalChangesModel.refresh(root:requestGeneration:)` rule:
    /// unstructured `Task`s are not guaranteed to start in creation order, so two
    /// rapid folder opens could otherwise settle on the older one.
    ///
    /// The index, the stamps and the buffer marks are cleared up front rather
    /// than merged into: a rebuild is what a *different project* gets, and
    /// keeping a previous root's entries around would leave them answering
    /// lookups for files the user cannot see.
    public func rebuild(root: URL, request: Int? = nil) async {
        if let request, request != generation { return }

        // A rebuild reached without `prepareForFolderChange` (a direct call, as
        // Core's own tests make) is still a project change if the folder differs,
        // and an in-flight buffer parse for the previous one must not publish
        // into this index.
        if root != lastRoot { rootGeneration += 1 }
        lastRoot = root
        generation += 1
        let token = generation
        clearIndex()

        await walk(root: root, token: token, stampGated: false)
    }

    // MARK: - Refresh

    /// Re-walk `root` and re-extract **only** the files whose stamp changed,
    /// dropping the ones the walk no longer sees.
    ///
    /// This is what an FSEvents burst runs (debounced by
    /// `SymbolIndexController`). The watcher reports only "something under the
    /// root changed" — directory-level events — so the alternative to a
    /// stamp-gated re-walk is re-parsing the whole project, which an `npm i`
    /// would then trigger every second.
    ///
    /// Three rules, in order of how often they fire:
    /// - a file whose `(byteCount, modificationDate)` stamp equals the recorded
    ///   one is skipped without being read;
    /// - a **buffer-sourced** file is skipped entirely — the buffer is ahead of
    ///   disk, and overwriting it with the saved text would drop symbols the user
    ///   has already typed;
    /// - a file the walk no longer produces (deleted, renamed, newly gitignored)
    ///   is removed from the index, unless a buffer owns it.
    ///
    /// A refresh naming a root the model is **not** currently indexing is
    /// discarded, and that is the whole stale-token defence: it takes no
    /// `request:` counterpart to `rebuild`'s because the root *is* the token. A
    /// refresh is only ever issued for a root someone is already watching, and a
    /// folder change always issues its own `prepareForFolderChange` + `rebuild`
    /// in the switching turn — so a refresh for another root can only be a
    /// callback from the folder the user just left. Rebuilding for it (what this
    /// used to do) would clear the index the switch just filled and repopulate it
    /// from the *previous* project, leaving every definition and completion
    /// answering out of a folder that is no longer open, with nothing to correct
    /// it until the next folder change. That is reachable in practice: the
    /// FSEvents callback hops to the main actor with `DispatchQueue.main.async`,
    /// so a batch enqueued while `openFolder` is running is delivered afterwards
    /// — with the previous root captured — however promptly the watcher was
    /// re-subscribed.
    public func refresh(root: URL) async {
        guard root == lastRoot else { return }

        generation += 1
        let token = generation

        await walk(root: root, token: token, stampGated: true)
    }

    /// The body both `rebuild` and `refresh` share: walk off-main, then extract
    /// chunk by chunk, re-checking the generation after **every** await.
    ///
    /// `stampGated` is the only difference between the two — a rebuild starts
    /// from an empty index, so gating it on stamps it just cleared would be a
    /// no-op with extra syscalls, and it must not remove anything.
    private func walk(root: URL, token: Int, stampGated: Bool) async {
        isIndexing = true

        let service = fileService
        // Everything this walk's buffer snapshot claims is true as of *now*; a tab
        // that closes from here on is recorded so `apply` can decline the
        // ownership its in-flight outcome would otherwise take.
        buffersClosedDuringWalk = []
        // One main-actor read of the workspace for the whole walk, canonicalized
        // off-main — `ProjectSearchModel`'s rule, for the same reason: a per-file
        // lookup would put a symlink resolution per open tab on the main thread
        // for every file in the project.
        let buffers = openBuffers()

        let (candidates, bufferIndex) = await offMain { () -> ([IndexCandidate], [String: String]) in
            let walked = Self.candidates(root: root, fileService: service)
            // An open tab the traversal cannot produce — a file under the folder
            // the user just left, or one this project's `.gitignore` excludes —
            // is indexed anyway, from its buffer. `prepareForFolderChange` clears
            // the buffer marks along with the index, and a walk is the only thing
            // that runs afterwards, so leaving these out would mean the file the
            // user is *looking at* answers nothing until they switch away and
            // back. `removeFiles` already states the same rule from the other
            // side: such a tab is exempt from removal.
            return (
                walked + Self.bufferCandidates(buffers, excluding: Set(walked.map(\.key))),
                Self.bufferIndex(buffers)
            )
        }
        guard token == generation else { return }

        if stampGated {
            removeFiles(missingFrom: Set(candidates.map(\.key)))
        }

        let extract = extractSymbols
        let byteCap = maxFileBytes
        var start = 0

        // Snapshotted **once** for the whole walk, unlike the buffer marks below.
        // `apply` writes stamps only for files in chunks it has already processed,
        // and a candidate appears in exactly one chunk, so a per-chunk copy would
        // never decide anything differently — while a second reference to the
        // dictionary held across `apply`'s mutation forces a full copy of it per
        // chunk, i.e. O(files²/chunk) element copies on the main actor for a pass
        // whose entire purpose is to avoid work.
        let knownStamps = stampGated ? stamps : [:]

        while start < candidates.count {
            let end = min(start + Self.chunkSize, candidates.count)
            let chunk = Array(candidates[start..<end])
            start = end

            // Snapshotted per chunk rather than for the whole walk: a
            // `reindexBuffer` that lands between two chunks must be visible to
            // the next one, or that chunk would republish the file from the
            // walk-time text and undo the edit (see `extractChunk`).
            let skippable = bufferSourced

            let outcomes = await offMain {
                Self.extractChunk(
                    candidates: chunk,
                    buffers: bufferIndex,
                    knownStamps: knownStamps,
                    bufferSourced: skippable,
                    fileService: service,
                    maxBytes: byteCap,
                    extract: extract
                )
            }
            guard token == generation else { return }

            apply(outcomes)
        }

        isIndexing = false
    }

    // MARK: - Buffers

    /// Re-extract one file from the **live buffer text** the editor holds, and
    /// mark its entry buffer-sourced.
    ///
    /// Called immediately on tab open/switch and, debounced, while typing
    /// (`SymbolIndexController`). The extraction runs in a one-file `offMain`
    /// block with a `rootGeneration` re-check after it, so a folder switch landing
    /// mid-parse discards the result instead of publishing the previous
    /// project's symbols into the new index. Deliberately *not* the walk's
    /// `generation` (see that property's note): a refresh starting while the parse
    /// is in flight must not throw the user's freshly typed symbols away.
    ///
    /// A language with no query is dropped before any work: it can declare
    /// nothing, so marking it buffer-sourced would only make a refresh skip a
    /// file that has no symbols either way.
    ///
    /// **Cancellation is honoured after the parse**, and that is load-bearing
    /// rather than a courtesy. `SymbolIndexController.noteBufferClosed` cancels
    /// the in-flight re-index and then calls `forgetBuffer`; without this check a
    /// parse already past its debounce would resume afterwards and
    /// `bufferSourced.insert` the file straight back, pinning the index to text
    /// no editor holds any more — a refresh would then skip that file forever and
    /// `removeFiles` would keep exempting it, so a since-deleted file would go on
    /// answering go-to-definition until the folder was reopened. The check and
    /// `apply` are one main-actor run with no suspension between them, so a
    /// cancellation either lands before it (nothing is published) or after the
    /// entry was applied (and `forgetBuffer` then clears it) — never in between.
    public func reindexBuffer(url: URL, text: String, language: SyntaxLanguage) async {
        guard Self.isIndexable(language) else { return }

        let token = rootGeneration
        let extract = extractSymbols
        let outcome = await offMain { () -> FileOutcome in
            let candidate = IndexCandidate(
                url: url,
                key: SymbolIndex.fileKey(for: url),
                language: language
            )
            return FileOutcome(
                candidate: candidate,
                symbols: extract(text, language, url),
                stamp: nil,
                source: .liveBuffer
            )
        }
        guard token == rootGeneration, !Task.isCancelled else { return }

        apply([outcome])
    }

    /// Forget that `url`'s entry came from a buffer — the first half of what a tab
    /// close means.
    ///
    /// The symbols stay for now: they are still the best knowledge available, and
    /// the file on disk is usually identical anyway (the tab was saved). What
    /// changes is who owns the entry: the stamp is cleared alongside the mark, so
    /// any later refresh re-extracts the file from disk unconditionally rather
    /// than concluding from an unchanged stamp that the buffer's version is
    /// current. **The other half is `reindexFromDisk(url:)`**, which a close must
    /// also call — see there for why "any later refresh" is not something a tab
    /// close may rely on.
    public func forgetBuffer(url: URL) {
        let key = SymbolIndex.fileKey(for: url)
        bufferSourced.remove(key)
        stamps[key] = nil
        // A walk may be holding an outcome for this file that was extracted from
        // the buffer this call just gave up; recording the key is what makes
        // `apply` drop it in favour of the hand-off below. See
        // `buffersClosedDuringWalk`.
        buffersClosedDuringWalk.insert(key)
    }

    /// Re-extract `url` from **disk**, now that no buffer owns its entry — the
    /// second half of a tab close, and the one that actually makes the hand-off
    /// happen.
    ///
    /// `forgetBuffer` only gives up the *ownership*; it leaves the symbols in
    /// place on the understanding that a refresh will re-derive them. Nothing
    /// schedules that refresh. A tab close writes nothing, so no watcher fires,
    /// and with no folder open — a standalone file, `lastRoot == nil` — `refresh`
    /// is unreachable by construction. Left at that, a buffer whose changes were
    /// *discarded*, or whose last keystrokes the close cancelled out of the
    /// debounce, would go on answering go-to-definition and completion with text
    /// that exists nowhere, for the rest of the session. Re-reading the one file
    /// involved closes that window at its source, and costs a single read rather
    /// than making every tab close walk the project.
    ///
    /// A file that can no longer be read — deleted, or closed *because* it was
    /// deleted — drops out of the index entirely: with neither a buffer nor a file
    /// behind it, there is nothing left its entry could be true of. One the
    /// service declines (binary or oversize) indexes as empty, exactly as a walk
    /// would.
    ///
    /// Ordered against the buffer path exactly as `reindexBuffer` is: the
    /// `rootGeneration` re-check drops the result of a folder switch that landed
    /// mid-read, cancellation is honoured after the read (a tab reopened while it
    /// was in flight cancels this and re-indexes immediately), and both `apply`
    /// and `dropIfUnowned` stand aside for a file that has become buffer-sourced
    /// again — so the editor's text always outranks the disk copy.
    public func reindexFromDisk(url: URL) async {
        guard let language = Self.indexableLanguage(forFileName: url.lastPathComponent) else { return }

        let token = rootGeneration
        let service = fileService
        let extract = extractSymbols
        let byteCap = maxFileBytes

        let result = await offMain { () -> (key: String, outcome: FileOutcome?) in
            let candidate = IndexCandidate(
                url: url,
                key: SymbolIndex.fileKey(for: url),
                language: language
            )
            // The walk's own per-file body, so a hand-off reads, gates and
            // classifies a file exactly as a refresh does — including the key,
            // resolved off-main once and used for both branches below. No known
            // stamp (the entry is being re-derived, not skipped) and no buffers
            // (that is the whole point of the call).
            let outcomes = Self.extractChunk(
                candidates: [candidate],
                buffers: [:],
                knownStamps: [:],
                bufferSourced: [],
                fileService: service,
                maxBytes: byteCap,
                extract: extract
            )
            return (candidate.key, outcomes.first)
        }
        guard token == rootGeneration, !Task.isCancelled else { return }

        if let outcome = result.outcome {
            apply([outcome])
        } else {
            dropIfUnowned(fileKey: result.key)
        }
    }

    // MARK: - Applying results

    /// Publish one batch of extraction outcomes.
    ///
    /// The buffer-over-disk rule lives here: **no walk outcome** — disk-read or
    /// walk-snapshot alike — overwrites a file a buffer already wrote. Both are
    /// text as it stood when the walk started, so publishing either would undo
    /// the re-index the user's keystroke has since caused, and the file is
    /// buffer-owned afterwards, so no refresh would ever correct it. Only a
    /// `liveBuffer` outcome, which by construction carries the editor's current
    /// text, is allowed through. A walk-snapshot outcome for a tab that closed
    /// mid-walk is not published at all — see `buffersClosedDuringWalk`.
    ///
    /// The batch is assembled in a local and written back to `index` **once**.
    /// `@Published` exposes only a get/set pair, so `index.replace(…)` inside the
    /// loop would be a get-mutate-set per file: every iteration holds a second
    /// reference to the value while mutating it, forcing a copy-on-write of all
    /// of `SymbolIndex`'s dictionaries — O(symbols²/chunk) element copies on the
    /// main actor — and republishing the whole index per file rather than per
    /// chunk. Same shape, and the same reason, as `walk`'s hoisted `knownStamps`.
    private func apply(_ outcomes: [FileOutcome]) {
        var updated = index
        for outcome in outcomes {
            let key = outcome.candidate.key
            if outcome.source != .liveBuffer && bufferSourced.contains(key) { continue }

            // A walk-snapshot outcome whose tab has since closed is dropped
            // whole, text and ownership alike. The mark would pin the entry to a
            // buffer that no longer exists, and the *text* is no better: the
            // close's `reindexFromDisk` hand-off re-derives this very file from
            // disk and may already have published, so republishing here would put
            // the closed buffer's text back over it with nothing scheduled to
            // correct it (see `buffersClosedDuringWalk`).
            if outcome.source == .walkBuffer && buffersClosedDuringWalk.contains(key) { continue }

            // Filed under the key the walk resolved off-main, never a freshly
            // derived one: `SymbolIndex.replace(fileKey:)` states both halves of
            // why (a symlink resolution per file on the main actor, and a key that
            // could diverge from the one `indexedFiles`/`stamps` track).
            updated.replace(fileKey: key, symbols: outcome.symbols)
            indexedFiles.insert(key)

            if outcome.source.isBuffer {
                bufferSourced.insert(key)
                // A buffer's text has no on-disk stamp; recording the file's
                // would claim the *disk* version was extracted and make the next
                // refresh skip it forever.
                stamps[key] = nil
            } else {
                stamps[key] = outcome.stamp
            }
        }
        index = updated
    }

    /// Drop every indexed file the walk stopped producing.
    ///
    /// Buffer-sourced files are exempt: an open tab may legitimately name a file
    /// outside the walked root (or one the project's `.gitignore` excludes), and
    /// removing its symbols would break completion in the very file being typed
    /// in.
    /// Removed **by key**, not by URL: the file is by definition gone, so asking
    /// `SymbolIndex` to re-canonicalize its URL is both a syscall on the main
    /// actor and a chance to derive a key the entry was never stored under.
    /// One write back to `index` for the whole set, for `apply`'s reason.
    private func removeFiles(missingFrom walked: Set<String>) {
        let gone = indexedFiles.subtracting(walked).subtracting(bufferSourced)
        guard !gone.isEmpty else { return }
        var updated = index
        for key in gone {
            updated.remove(fileKey: key)
            stamps[key] = nil
        }
        index = updated
        indexedFiles.subtract(gone)
    }

    /// Drop one file's entry unless a buffer owns it — `removeFiles` for a single
    /// file, and it makes the same exemption for the same reason: a tab reopened
    /// while `reindexFromDisk`'s read was in flight owns the entry, and dropping
    /// it would empty completion in the very file being typed in.
    ///
    /// Takes the key the caller resolved off-main rather than a URL, for
    /// `removeFiles`' reason: the file is by definition gone, so re-canonicalizing
    /// it is both a syscall on the main actor and a chance to derive a key the
    /// entry was never stored under.
    private func dropIfUnowned(fileKey key: String) {
        guard indexedFiles.contains(key), !bufferSourced.contains(key) else { return }
        var updated = index
        updated.remove(fileKey: key)
        index = updated
        indexedFiles.remove(key)
        stamps[key] = nil
    }

    /// Clear everything the model knows, synchronously — the folder-change reset.
    private func clearIndex() {
        index = SymbolIndex()
        indexedFiles = []
        stamps = [:]
        bufferSourced = []
    }

    /// Run `work` on the private serial queue and resume with its result — the
    /// `ProjectSearchModel.offMain` / `GitCLIService.run(_:in:)` shape, so file
    /// I/O and tree-sitter parses never land on the main thread while the model
    /// itself stays `@MainActor`.
    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Pure helpers

    /// One file the walk decided is worth extracting, with everything the
    /// off-main batch needs already resolved: its canonical index key (a symlink
    /// resolution, so it is computed once, off-main, rather than per lookup) and
    /// its language.
    struct IndexCandidate: Equatable, Sendable {
        let url: URL
        let key: String
        let language: SyntaxLanguage
    }

    /// Where the text one outcome was extracted from came from.
    ///
    /// Three cases rather than a `fromBuffer` flag, because the two buffer cases
    /// differ in exactly the way `apply` has to arbitrate. Both take ownership of
    /// the entry, but only one of them is *current*: the walk reads the workspace
    /// once, before it starts, so a chunk's buffer text can already be several
    /// keystrokes old by the time it is applied.
    enum OutcomeSource: Equatable, Sendable {
        /// Read from the file itself.
        case disk
        /// The walk-time snapshot of an open tab — a buffer's authority, but not
        /// necessarily its freshness.
        case walkBuffer
        /// A `reindexBuffer` of the text the editor holds *now*.
        case liveBuffer

        /// Whether the entry this produces is owned by an editor buffer.
        var isBuffer: Bool { self != .disk }
    }

    /// What one file's extraction produced. A file the batch *skipped* (unchanged
    /// stamp, unreadable) simply yields no outcome, so "keep what is indexed"
    /// needs no separate case.
    struct FileOutcome: Equatable, Sendable {
        let candidate: IndexCandidate
        let symbols: [Symbol]
        /// The stamp the file had when it was read, or `nil` for buffer text.
        let stamp: FileStamp?
        let source: OutcomeSource
    }

    /// Every file under `root` worth indexing, in traversal order.
    ///
    /// The shared `ProjectFileWalk.collectFiles` with no file mask, then the
    /// language gate: a file whose name resolves to no language, or to one with
    /// no `symbols.scm`, is dropped **before** it is read.
    nonisolated static func candidates(root: URL, fileService: FileServicing) -> [IndexCandidate] {
        ProjectFileWalk.collectFiles(root: root, maskPatterns: [], fileService: fileService)
            .compactMap { url in
                guard let language = indexableLanguage(forFileName: url.lastPathComponent) else {
                    return nil
                }
                return IndexCandidate(url: url, key: SymbolIndex.fileKey(for: url), language: language)
            }
    }

    /// Extract one batch of files, preferring an open buffer's text over the
    /// file's on-disk contents, and skipping what has not changed.
    ///
    /// Runs entirely off the main actor, and calls `extract` synchronously once
    /// per file — the seam described on the type. A file that throws on read
    /// produces no outcome at all (it keeps whatever the index already holds and
    /// is retried on the next refresh); a file the service declines to hand over
    /// — binary or oversize — is indexed as *empty*, so it is not re-read on
    /// every refresh only to be rejected again.
    nonisolated static func extractChunk(
        candidates: [IndexCandidate],
        buffers: [String: String],
        knownStamps: [String: FileStamp],
        bufferSourced: Set<String>,
        fileService: FileServicing,
        maxBytes: Int,
        extract: @Sendable (String, SyntaxLanguage, URL) -> [Symbol]
    ) -> [FileOutcome] {
        var outcomes: [FileOutcome] = []

        for candidate in candidates {
            // A file a buffer already wrote is left alone — **before** the buffer
            // snapshot is consulted, not after. `buffers` was read once when the
            // walk started, so for a file the user is typing in it is already
            // behind, and re-parsing it would only produce an outcome `apply`
            // rejects (as `.walkBuffer`, which never outranks a buffer-owned
            // entry). Skipping is also what this model documents a refresh does
            // with a buffer-sourced file — entirely, without being read or
            // re-parsed — and the parse was wasted either way, since the buffer
            // owns the entry until `forgetBuffer`.
            //
            // This snapshot is taken per chunk, so it closes the window only up to
            // the chunk's dispatch; a `reindexBuffer` landing while the chunk runs
            // is caught by `apply`'s guard instead.
            if bufferSourced.contains(candidate.key) { continue }

            // Not yet buffer-sourced: this is the first walk that has seen the
            // tab, so its text is the freshest thing available and indexing it
            // both fills the entry and takes ownership of it. With no tabs open
            // the dictionary is not even consulted, which is the common
            // fresh-project case.
            if let text = buffers.isEmpty ? nil : buffers[candidate.key] {
                outcomes.append(
                    FileOutcome(
                        candidate: candidate,
                        symbols: extract(text, candidate.language, candidate.url),
                        stamp: nil,
                        source: .walkBuffer
                    )
                )
                continue
            }

            let stamp = fileService.fileStamp(at: candidate.url)
            if let stamp, let known = knownStamps[candidate.key], known == stamp { continue }

            do {
                guard let text = try fileService.readTextIfNotBinary(url: candidate.url, maxBytes: maxBytes) else {
                    outcomes.append(
                        FileOutcome(candidate: candidate, symbols: [], stamp: stamp, source: .disk)
                    )
                    continue
                }
                outcomes.append(
                    FileOutcome(
                        candidate: candidate,
                        symbols: extract(text, candidate.language, candidate.url),
                        stamp: stamp,
                        source: .disk
                    )
                )
            } catch {
                continue
            }
        }

        return outcomes
    }

    /// The open tabs the traversal did not produce, as candidates in their own
    /// right — the walk's "index what the user can see" half.
    ///
    /// Same language gate as `candidates`, so a tab on a plain-text or
    /// unindexable file still costs nothing, and the same canonical key, so a tab
    /// opened through a symlink is recognized as the file the walk already found
    /// rather than indexed a second time. Ordered by key so a walk is
    /// deterministic: a dictionary's iteration order is not.
    ///
    /// These candidates carry no on-disk existence claim. `extractChunk` finds
    /// each of them in the buffer snapshot and never reaches its disk branch,
    /// which is what makes a tab on a file outside the root — or on one that has
    /// since been deleted from it — safe to include.
    nonisolated static func bufferCandidates(
        _ buffers: [URL: String],
        excluding walked: Set<String>
    ) -> [IndexCandidate] {
        buffers.keys.compactMap { url in
            guard let language = indexableLanguage(forFileName: url.lastPathComponent) else {
                return nil
            }
            let key = SymbolIndex.fileKey(for: url)
            guard !walked.contains(key) else { return nil }
            return IndexCandidate(url: url, key: key, language: language)
        }
        .sorted { $0.key < $1.key }
    }

    /// A snapshot of the open tabs re-keyed by canonical path, so a candidate is
    /// matched with a single dictionary hit.
    ///
    /// The key is `SymbolIndex.fileKey(for:)` — the same
    /// `CanonicalPath.canonical(_:).path` transform `ProjectSearchModel`'s buffer
    /// index and `WorkspaceModel.fileID(forURL:)` use — so a tab opened through a
    /// symlink still matches the file the traversal produced.
    nonisolated static func bufferIndex(_ buffers: [URL: String]) -> [String: String] {
        var index: [String: String] = [:]
        index.reserveCapacity(buffers.count)
        for (url, text) in buffers { index[SymbolIndex.fileKey(for: url)] = text }
        return index
    }
}
