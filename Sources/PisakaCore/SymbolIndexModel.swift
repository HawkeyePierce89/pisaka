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

    /// File key → the URL that key was filed under, for every file currently in
    /// the index.
    ///
    /// `SymbolIndex` is keyed by canonical path and does not hand its keys back;
    /// this is what lets a refresh compute "which indexed files did the walk stop
    /// seeing" as a set difference, and remembers the URL each removal needs.
    private var indexedFiles: [String: URL] = [:]

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

        // A rebuild reached without `prepareForFolderChange` (a refresh for an
        // unknown root, or a direct call) is still a project change if the folder
        // differs, and an in-flight buffer parse for the previous one must not
        // publish into this index.
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
    /// A refresh for a *different* root is a folder change wearing a refresh's
    /// clothes, and runs as a `rebuild` — no stamp from the previous project may
    /// gate a file in this one.
    ///
    /// No `request:` counterpart to `rebuild`'s: a refresh is issued by the
    /// watcher debounce for whatever root is current, never deferred across a
    /// folder change, so there is no stale token to reject. The root check below
    /// is what stands in for one.
    public func refresh(root: URL) async {
        guard root == lastRoot else {
            await rebuild(root: root)
            return
        }

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
        // One main-actor read of the workspace for the whole walk, canonicalized
        // off-main — `ProjectSearchModel`'s rule, for the same reason: a per-file
        // lookup would put a symlink resolution per open tab on the main thread
        // for every file in the project.
        let buffers = openBuffers()

        let (candidates, bufferIndex) = await offMain {
            (
                Self.candidates(root: root, fileService: service),
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

        while start < candidates.count {
            let end = min(start + Self.chunkSize, candidates.count)
            let chunk = Array(candidates[start..<end])
            start = end

            // Snapshotted per chunk rather than for the whole walk: a
            // `reindexBuffer` that lands between two chunks must be visible to
            // the next one, or that chunk would republish the file from the
            // walk-time text and undo the edit (see `extractChunk`).
            let knownStamps = stampGated ? stamps : [:]
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
                fromBuffer: true
            )
        }
        guard token == rootGeneration, !Task.isCancelled else { return }

        apply([outcome])
    }

    /// Forget that `url`'s entry came from a buffer — what a tab close means.
    ///
    /// The symbols stay: they are still the best knowledge available, and the
    /// file on disk is usually identical anyway (the tab was saved). What changes
    /// is who owns the entry: the stamp is cleared alongside the mark, so the
    /// next refresh re-extracts the file from disk unconditionally rather than
    /// concluding from an unchanged stamp that the buffer's version is current.
    public func forgetBuffer(url: URL) {
        let key = SymbolIndex.fileKey(for: url)
        bufferSourced.remove(key)
        stamps[key] = nil
    }

    // MARK: - Applying results

    /// Publish one batch of extraction outcomes.
    ///
    /// The buffer-over-disk rule lives here: a disk-sourced outcome for a file a
    /// buffer already wrote is dropped, because the chunk read that file's text
    /// before the edit and publishing it would undo the re-index the user's
    /// keystroke just caused.
    private func apply(_ outcomes: [FileOutcome]) {
        for outcome in outcomes {
            let key = outcome.candidate.key
            if !outcome.fromBuffer && bufferSourced.contains(key) { continue }

            index.replace(fileURL: outcome.candidate.url, symbols: outcome.symbols)
            indexedFiles[key] = outcome.candidate.url

            if outcome.fromBuffer {
                bufferSourced.insert(key)
                // A buffer's text has no on-disk stamp; recording the file's
                // would claim the *disk* version was extracted and make the next
                // refresh skip it forever.
                stamps[key] = nil
            } else {
                stamps[key] = outcome.stamp
            }
        }
    }

    /// Drop every indexed file the walk stopped producing.
    ///
    /// Buffer-sourced files are exempt: an open tab may legitimately name a file
    /// outside the walked root (or one the project's `.gitignore` excludes), and
    /// removing its symbols would break completion in the very file being typed
    /// in.
    private func removeFiles(missingFrom walked: Set<String>) {
        for (key, url) in indexedFiles
        where !walked.contains(key) && !bufferSourced.contains(key) {
            index.remove(fileURL: url)
            indexedFiles[key] = nil
            stamps[key] = nil
        }
    }

    /// Clear everything the model knows, synchronously — the folder-change reset.
    private func clearIndex() {
        index = SymbolIndex()
        indexedFiles = [:]
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

    /// What one file's extraction produced. A file the batch *skipped* (unchanged
    /// stamp, unreadable) simply yields no outcome, so "keep what is indexed"
    /// needs no separate case.
    struct FileOutcome: Equatable, Sendable {
        let candidate: IndexCandidate
        let symbols: [Symbol]
        /// The stamp the file had when it was read, or `nil` for buffer text.
        let stamp: FileStamp?
        /// Whether the text came from a live editor buffer.
        let fromBuffer: Bool
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
            // behind: a `reindexBuffer` that has since published those keystrokes
            // would be silently overwritten here by the text as it stood at walk
            // time, and the outcome carries `fromBuffer: true` so `apply` has
            // nothing left to reject it with. Skipping is also what this model
            // documents a refresh does with a buffer-sourced file — entirely,
            // without being read or re-parsed — and the parse was wasted either
            // way, since the buffer owns the entry until `forgetBuffer`.
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
                        fromBuffer: true
                    )
                )
                continue
            }

            let stamp = fileService.fileStamp(at: candidate.url)
            if let stamp, let known = knownStamps[candidate.key], known == stamp { continue }

            do {
                guard let text = try fileService.readTextIfNotBinary(url: candidate.url, maxBytes: maxBytes) else {
                    outcomes.append(
                        FileOutcome(candidate: candidate, symbols: [], stamp: stamp, fromBuffer: false)
                    )
                    continue
                }
                outcomes.append(
                    FileOutcome(
                        candidate: candidate,
                        symbols: extract(text, candidate.language, candidate.url),
                        stamp: stamp,
                        fromBuffer: false
                    )
                )
            } catch {
                continue
            }
        }

        return outcomes
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
