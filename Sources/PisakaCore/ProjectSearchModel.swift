import Foundation

/// The one line a match sits on, ready to be drawn in a result row.
///
/// `text` is the match's logical line with its separator stripped, clipped to a
/// window around the match (a minified bundle's single 200 KB line must not turn
/// into a 200 KB result row), and `matchRange` is the match's own UTF-16 range
/// *within that window*, so the view highlights it without re-deriving any
/// column arithmetic.
public struct MatchPreview: Equatable {
    /// The clipped line text — no line separator, so a row is always one line.
    public var text: String
    /// The match's range inside `text`, clamped to it (a match longer than the
    /// window shows its head).
    public var matchRange: NSRange

    public init(text: String, matchRange: NSRange) {
        self.text = text
        self.matchRange = matchRange
    }
}

/// Every hit in one file, in document order.
///
/// `matches` and `previews` are parallel arrays (index *i* of one describes index
/// *i* of the other) rather than one array of pairs, so the view can pass
/// `matches` straight to the editor's selection path — the shape
/// `TextSearchEngine` already speaks — while reading previews alongside it.
public struct FileSearchResult: Equatable {
    /// The file's absolute URL (what the view opens on activation).
    public var fileURL: URL
    /// The file's path relative to the searched project root (the group header).
    public var relativePath: String
    /// The matches, ascending by location.
    public var matches: [SearchMatch]
    /// One preview per entry of `matches`, in the same order.
    public var previews: [MatchPreview]

    public init(fileURL: URL, relativePath: String, matches: [SearchMatch], previews: [MatchPreview]) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.matches = matches
        self.previews = previews
    }

    public var matchCount: Int { matches.count }
}

/// What a project-wide Replace All did, counted per file so the view can state
/// the outcome plainly instead of implying every match was rewritten.
///
/// `filesSkipped` and `errors` are deliberately separate: a *skipped* file is one
/// the batch declined to touch because it no longer looks the way the results
/// describe it (the `LocalChangesModel.guardRevert` philosophy — a stale snapshot
/// must never be applied blind), while an *error* is a read or write that
/// actually failed. Neither stops the batch.
public struct ReplaceSummary: Equatable {
    /// Files whose contents were rewritten — on disk, or in an open buffer.
    public var filesChanged: Int
    /// Matches replaced across every changed file.
    public var matchesReplaced: Int
    /// Files left untouched because their contents no longer matched the
    /// captured results.
    public var filesSkipped: Int
    /// One human-readable line per file that could not be read or written.
    public var errors: [String]
    /// Whether the batch stopped early because the opened folder changed under
    /// it, leaving the rest of the snapshot untouched.
    ///
    /// The counts still describe what was actually written before the switch, so
    /// a caller can both refresh for those files and say plainly that the batch
    /// was cut short — a zeroed summary would read as "nothing matched" for a
    /// batch that had already rewritten files.
    public var abandoned: Bool

    public init(
        filesChanged: Int = 0,
        matchesReplaced: Int = 0,
        filesSkipped: Int = 0,
        errors: [String] = [],
        abandoned: Bool = false
    ) {
        self.filesChanged = filesChanged
        self.matchesReplaced = matchesReplaced
        self.filesSkipped = filesSkipped
        self.errors = errors
        self.abandoned = abandoned
    }

    /// Whether anything at all happened — the view shows a "no changes" note
    /// rather than an empty report. An abandoned batch is never empty: "the
    /// folder changed under it" is itself an outcome the user must be told.
    public var isEmpty: Bool {
        filesChanged == 0 && filesSkipped == 0 && errors.isEmpty && !abandoned
    }
}

/// Observable state for the project-wide "Find in Files": the traversal of the
/// opened folder and the search of every file it decides is worth reading.
///
/// Mirrors `LocalChangesModel`/`CommitLogModel`'s shape — an `@MainActor
/// ObservableObject` whose I/O is injected behind `FileServicing`, whose
/// branching decisions are pure static helpers, and whose overlapping
/// operations are ordered by a generation token captured synchronously
/// (`prepareForSearch`) before any `Task` hop. Pure Foundation: no
/// AppKit/SwiftUI, and no reference to `WorkspaceModel` — the open buffers reach
/// it through an injected `openBuffers` snapshot closure, so Core stays unaware
/// of the workspace.
///
/// **What is skipped, and by whom.** The traversal itself is
/// `ProjectFileWalk.collectFiles`, shared with the symbol index so both features
/// see exactly the same set of files. `.git` and `.DS_Store` are skipped there
/// (`FileService.isExcludedEntryName`) — `GitignoreMatcher`
/// deliberately says nothing about them. Every other exclusion is a
/// `.gitignore` decision, composed down the tree by `GitignoreStack`. Binary and
/// oversize files are skipped by `FileServicing.readTextIfNotBinary`, and a
/// symlinked *directory* is not descended into (a link back up the tree would
/// otherwise walk forever, and its target is already visited under its real
/// name).
///
/// **Where the work runs.** The directory walk and the per-file read+match run
/// on a private serial queue (`GitCLIService`'s shape) so a large project never
/// blocks the main thread; only the published state is touched on the main
/// actor. That is why the open buffers arrive as **one snapshot taken before the
/// walk** rather than as a per-file lookup: the closure reads the workspace, so
/// it must run on the main actor, and matching a candidate against the open tabs
/// costs a `CanonicalPath.canonical` symlink resolution *per tab*. Asking it per
/// traversed file would put `files × (1 + tabs)` of those on the main thread —
/// measurably more, on a project of ordinary source files, than the off-main
/// read the chunk is dispatched to do. Snapshotting once turns that into `tabs`
/// resolutions on the main actor plus one *off-main* resolution per file.
/// Results are published per chunk, so rows appear while the search continues,
/// and the generation token is re-checked after *every* `await` — a superseded
/// search drops its partial results instead of interleaving them with the newer
/// one's.
@MainActor
public final class ProjectSearchModel: ObservableObject {
    // The constants are `nonisolated` because the `nonisolated static` helpers
    // (`collectFiles`, `preview`, …) and the `init` default arguments read them
    // from outside the main actor; without it they inherit the class's isolation
    // and every such reference is a Swift 6 error (a Swift 5 warning today).

    /// The most matches a single search will collect before reporting
    /// `truncated`. A cap is what keeps a one-character query on a large
    /// repository from building a multi-million-row list nobody can read.
    public nonisolated static let defaultMaxMatches = 10_000

    /// The largest file the search will read (1 MiB). Beyond this a file is
    /// almost always generated (a bundle, a lockfile, a fixture), and reading it
    /// costs more than the hit is worth.
    public nonisolated static let defaultMaxFileBytes = 1 << 20

    /// How many files one off-main batch reads before publishing. Small enough
    /// that results stream in visibly, large enough that the per-hop cost stays
    /// negligible next to the file reads.
    nonisolated static let chunkSize = 32

    /// Preview window: at most this many UTF-16 units of the match's line…
    nonisolated static let previewWindow = 300
    /// …starting at most this far before the match, so a hit deep in a long line
    /// is still visible in its row.
    nonisolated static let previewLead = 40


    /// The hits of the last (or currently running) search, grouped by file in
    /// traversal order. Published per chunk while a search runs.
    @Published public private(set) var results: [FileSearchResult] = []

    /// `true` from the moment a search begins until it finishes or is superseded.
    @Published public private(set) var isSearching = false

    /// `true` when the match cap stopped the search before the tree was fully
    /// walked — the view says so rather than implying the list is complete.
    @Published public private(set) var truncated = false

    /// The reason the last search could not run (an invalid regular expression),
    /// or `nil`. An *empty* pattern is not an error — it is "no query", and
    /// clears the results silently.
    @Published public private(set) var errorMessage: String?

    /// The query the last search *ran*, recorded by `search` at its start (and
    /// cleared by `prepareForSearch`), so a caller can read it to re-run or to
    /// compare against the controls it is showing.
    ///
    /// In this app it is written by **nothing else**: `ProjectSearchView` keeps
    /// its own `@State` for the field and only reads this, which is exactly what
    /// makes it "the query that produced the rows on screen" and lets the view's
    /// `resultsMatchControls` gate act on that. A caller that instead *binds* a
    /// live field to it breaks that reading — and must then compare its controls
    /// against the search's own snapshot rather than against this.
    @Published public var query = SearchQuery(pattern: "")

    /// The query that produced the current `results`, captured as their pair.
    ///
    /// This is defense-in-depth for the fact that `query` is a settable public
    /// `@Published`: nothing in this app writes it outside `search`, so the two
    /// are equal at every `replaceAll` entry, but a caller that bound a live
    /// field to `query` would make them diverge the moment the user edited it
    /// without re-searching. `replaceAll` re-matches every file against the query
    /// the rows actually came from — this one — because matching the captured
    /// ranges against a pattern nothing was searched with makes *every* file fail
    /// the staleness check: the data is still safe (nothing is written), but the
    /// batch reports "everything skipped" for a result list that is in fact
    /// perfectly current, which reads as a bug in the replacement rather than as
    /// a stale field.
    ///
    /// Written wherever `results` is (`search` publishes both together,
    /// `prepareForSearch` clears both), so the pairing cannot drift.
    private var resultsQuery = SearchQuery(pattern: "")

    /// The file mask (`*.ts,*.tsx`) the last search ran with, recorded by
    /// `search` the same way as `query`. Empty means every file.
    @Published public var fileMask = ""

    private let fileService: FileServicing
    private let openBuffers: () -> [URL: String]
    private let applyBufferText: (URL, String) -> Bool
    private let maxMatches: Int
    private let maxFileBytes: Int

    /// Serial, so the traversal and every chunk read run one after another off
    /// the main thread (and so an injected stub is never touched concurrently).
    private let queue = DispatchQueue(label: "ws.karmanov.pisaka.project-search", qos: .userInitiated)

    /// Monotonically increasing token identifying the latest search *request*.
    /// Bumped by `search` at entry and by `prepareForSearch` on a folder change;
    /// a running search commits published state only while its captured token is
    /// still the latest.
    private var generation = 0

    /// Monotonically increasing token identifying the searched *project*, bumped
    /// only when the folder actually changes.
    ///
    /// Separate from `generation` for the reason `LocalChangesModel` keeps
    /// `rootRequestGeneration` apart from `operationGeneration`: a *query* change
    /// must supersede a running search (its results describe the wrong pattern)
    /// but must **not** abandon a running `replaceAll`, which works from a
    /// snapshot it already holds and re-verifies every file immediately before
    /// writing it. Aborting there would leave files rewritten on disk while the
    /// caller was told nothing happened — so `replaceAll` guards on this token
    /// and only a genuine folder switch stops it.
    private var rootGeneration = 0

    /// The folder last searched or prepared for, so `prepareForSearch` can tell a
    /// genuine folder switch from a repeat call.
    private var lastRoot: URL?

    /// - Parameters:
    ///   - openBuffers: the *unsaved* text of every open editor tab that has a
    ///     URL, keyed by that URL (a url-less "Untitled" buffer names no file on
    ///     disk, so it is left out and can never be matched). Called on the main
    ///     actor — so the app's closure may read `WorkspaceModel` directly —
    ///     **once** per search, before the walk, and once per file during Replace
    ///     All (where a fresh read is the point: a tab opened, or edited, while
    ///     the batch runs must be seen). A tab's text is searched and replaced
    ///     instead of the file on disk, so results match what the user sees. It
    ///     is a whole-snapshot closure rather than a per-URL lookup because
    ///     matching one candidate against the tabs costs a symlink resolution per
    ///     tab; see the type's "Where the work runs" note.
    ///   - applyBufferText: write replaced text back into that open tab,
    ///     returning whether it landed. Called on the main actor. The counterpart
    ///     of `openBuffers`, and the reason Replace All keeps an open file's
    ///     unsaved edits: a buffered file is edited *in the buffer* and stays
    ///     dirty rather than being written to disk behind the editor's back. The
    ///     default refuses, so a caller that provides `openBuffers` without this
    ///     gets a reported error rather than a silently dropped replacement.
    public init(
        fileService: FileServicing = FileService(),
        openBuffers: @escaping () -> [URL: String] = { [:] },
        applyBufferText: @escaping (URL, String) -> Bool = { _, _ in false },
        maxMatches: Int = ProjectSearchModel.defaultMaxMatches,
        maxFileBytes: Int = ProjectSearchModel.defaultMaxFileBytes
    ) {
        self.fileService = fileService
        self.openBuffers = openBuffers
        self.applyBufferText = applyBufferText
        self.maxMatches = maxMatches
        self.maxFileBytes = maxFileBytes
    }

    // MARK: - Generation

    /// Synchronously record that the searched project is switching to `root`
    /// (`nil` when the folder was closed), returning the request generation the
    /// switch produced.
    ///
    /// The `LocalChangesModel.prepareForFolderChange` precedent, and for the same
    /// reason: the app calls this in the same main-actor turn that handles the
    /// folder open, *before* spawning any `Task`, so an in-flight search resumes
    /// to find itself superseded rather than publishing the previous project's
    /// files into the new one's window. It also clears the stale results up
    /// front, so nothing from the old project stays clickable while the new one
    /// is being walked. A repeat call for the same folder is a no-op that returns
    /// the current generation.
    ///
    /// `query`/`fileMask` are reset along with the results, and that pairing is
    /// load-bearing rather than tidiness. The two record *what produced the rows*,
    /// which is how a view tells rows that answer its current controls from stale
    /// ones; leaving them describing a query this project was never searched with,
    /// next to an empty `results`, reads as "that query genuinely matched nothing
    /// here" — so a window left open across a folder switch would state "No
    /// results" about a project it never walked, and would let a Replace All be
    /// armed from rows belonging to the folder the user just left. Cleared, the
    /// rows and the controls honestly disagree until a search actually runs. No
    /// search is spawned here: the Find in Files window searches only when asked.
    @discardableResult
    public func prepareForSearch(root: URL?) -> Int {
        guard root != lastRoot else { return generation }
        lastRoot = root
        generation += 1
        rootGeneration += 1
        results = []
        truncated = false
        errorMessage = nil
        isSearching = false
        query = SearchQuery(pattern: "")
        resultsQuery = SearchQuery(pattern: "")
        fileMask = ""
        return generation
    }

    /// The current request generation, captured synchronously by a caller that
    /// defers a `search` across a `Task` hop and passes it back as `request:`.
    public var currentRequestGeneration: Int { generation }

    /// The current **project** generation, captured synchronously by a caller that
    /// defers a `replaceAll` across a `Task` hop and passes it back as
    /// `originGeneration:`.
    ///
    /// This is the very token `replaceAll` guards on, and it is deliberately *not*
    /// `currentRequestGeneration`: a query change bumps the request token, and a
    /// batch pinned to that would abort itself the moment the user typed in the
    /// still-live query field — after files had already been rewritten. Only a
    /// genuine folder switch moves this one.
    public var currentRootGeneration: Int { rootGeneration }

    // MARK: - Search

    /// Walk `root` and collect every match of `query` in the files that survive
    /// the gitignore/mask/binary/size filters.
    ///
    /// A `request` that a newer folder change has superseded is rejected before
    /// any work (the `LocalChangesModel.refresh(root:requestGeneration:)` rule —
    /// unstructured `Task`s are not guaranteed to start in creation order, so
    /// two rapid folder opens could otherwise settle on the older one).
    ///
    /// An empty/whitespace-only pattern clears the results with no error; an
    /// invalid regular expression clears them and publishes its reason. Both are
    /// judged up front by running the engine against an empty buffer, so the
    /// pattern is validated exactly once and by exactly the same code that will
    /// search the files.
    public func search(root: URL, query: SearchQuery, mask: String, request: Int? = nil) async {
        if let request, request != generation { return }

        self.query = query
        // The rows this search is about to publish (including the empty list it
        // clears them to below) are the rows for *this* query, so the pair is
        // recorded here rather than at the end: only the latest search ever
        // commits `results`, and it is also the last writer of this.
        self.resultsQuery = query
        self.fileMask = mask
        // A direct `search` for a different folder is a project switch too, even
        // when `prepareForSearch` was not called (the tests take this path).
        if root != lastRoot { rootGeneration += 1 }
        lastRoot = root
        generation += 1
        let token = generation

        results = []
        truncated = false
        errorMessage = nil

        do {
            _ = try TextSearchEngine.matches(in: "" as NSString, query: query)
        } catch TextSearchError.emptyPattern {
            isSearching = false
            return
        } catch {
            isSearching = false
            errorMessage = error.localizedDescription
            return
        }

        isSearching = true
        let patterns = Self.maskPatterns(mask)
        let service = fileService
        let byteCap = maxFileBytes
        // One main-actor read of the workspace for the whole search: the tabs are
        // canonicalized into a lookup off-main, so the walk below never touches
        // the main thread per file (see "Where the work runs").
        let buffers = openBuffers()

        let (files, bufferIndex) = await offMain {
            (
                Self.collectFiles(root: root, maskPatterns: patterns, fileService: service),
                Self.bufferIndex(buffers)
            )
        }
        guard token == generation else { return }

        var collected: [FileSearchResult] = []
        var matchTotal = 0
        var didTruncate = false
        var index = 0

        while index < files.count && !didTruncate {
            let end = min(index + Self.chunkSize, files.count)
            let chunk = Array(files[index..<end])
            index = end

            // One *over* what the cap can still accept, so the clipping loop
            // below keeps seeing the overflow that sets `truncated` while the
            // chunk never materializes previews it is going to discard.
            let budget = maxMatches - matchTotal + 1

            let found = await offMain {
                Self.searchChunk(
                    files: chunk,
                    buffers: bufferIndex,
                    root: root,
                    query: query,
                    fileService: service,
                    maxBytes: byteCap,
                    matchBudget: budget
                )
            }
            guard token == generation else { return }

            for result in found {
                let remaining = maxMatches - matchTotal
                if remaining <= 0 {
                    didTruncate = true
                    break
                }
                if result.matches.count > remaining {
                    collected.append(
                        FileSearchResult(
                            fileURL: result.fileURL,
                            relativePath: result.relativePath,
                            matches: Array(result.matches.prefix(remaining)),
                            previews: Array(result.previews.prefix(remaining))
                        )
                    )
                    matchTotal = maxMatches
                    didTruncate = true
                    break
                }
                collected.append(result)
                matchTotal += result.matches.count
            }

            results = collected
            truncated = didTruncate
        }

        results = collected
        truncated = didTruncate
        isSearching = false
    }

    // MARK: - Replace

    /// Replace every match in `results` with `template`, file by file, and report
    /// what happened.
    ///
    /// **Two branches, one rule.** A file with an open editor tab is replaced *in
    /// the buffer* through `applyBufferText` — this batch never writes it to disk
    /// — so the tab's own unsaved edits survive instead of being overwritten by a
    /// disk write behind the editor's back; every other file is read, rewritten
    /// and written back through `FileServicing`. (The buffer branch is not a
    /// promise that the result stays unsaved: on macOS the app's autosave writes
    /// those buffers shortly after the batch, like any other edit.)
    ///
    /// The branch is chosen *before* the file's hop, so the disk branch reconciles
    /// a tab that **opened while its write was in flight**
    /// (`reconcileBufferOpenedDuringWrite(url:original:replaced:)`) — otherwise
    /// that tab would sit there clean, holding the pre-replacement text, and a
    /// later save would write it back over the batch's result.
    ///
    /// **Nothing is applied blind.** `results` is a snapshot, and this is a
    /// destructive batch, so each file is re-read and re-matched *immediately
    /// before* its write (`LocalChangesModel.revert`'s per-file re-query, for the
    /// same reason: the window shrinks from "however long the list has been on
    /// screen" to the microseconds between the check and the write). A file whose
    /// leading matches no longer sit exactly where the results say is **skipped
    /// and counted**, not clobbered. The comparison is on the *leading* matches
    /// rather than the whole list because the match cap can clip a file's list
    /// mid-way (`truncated`), and a match appearing after every captured one
    /// cannot invalidate any of them — while a shifted, resized, added-before or
    /// vanished match makes every later range suspect.
    ///
    /// A per-file read or write failure is recorded in `errors` and the batch
    /// continues — one permission-denied file must not strand the rest.
    ///
    /// The **project** token (`rootGeneration`) is re-checked after every `await`,
    /// so a folder switch mid-batch stops the walk rather than continuing to
    /// rewrite files for a project the user has left. It returns the counts
    /// accumulated so far with `abandoned` set — *not* a zeroed summary: the
    /// files written before the switch really were written, so reporting nothing
    /// would tell the user "no file matched" about a batch that had already
    /// changed their project, and would skip the caller's Local Changes / tree
    /// refresh for those files. The file already in flight when the switch landed
    /// keeps its write: this rolls nothing back (neither does `git checkout`, and
    /// a partial batch that silently reverted would be worse than one that
    /// reports honestly). A new *query* for the same project deliberately does
    /// **not** stop the batch — see `rootGeneration` for why abandoning a
    /// partially applied summary there would be the worse outcome.
    ///
    /// The re-match runs against `resultsQuery` — the query that produced the
    /// snapshot — rather than the live, view-bound `query`, which the user can
    /// edit without re-searching. Judging a current result list by a pattern
    /// nothing was searched with makes every file fail the staleness check, so
    /// the batch would write nothing and report "everything skipped": the data
    /// stays safe either way, but that summary describes a defect in the
    /// replacement rather than a field the user had moved on from.
    ///
    /// `results` is left as it was — it now describes pre-replacement text, so
    /// the caller re-runs the search afterwards.
    ///
    /// `originGeneration` is the `LocalChangesModel.revert(_:originGeneration:)`
    /// precedent: the project token the caller captured **synchronously**, in the
    /// same main-actor turn as the click that confirmed the batch, *before* it
    /// hopped onto a `Task`. The body samples `rootGeneration` only when it
    /// actually starts — a later turn — so a folder switch that fully commits in
    /// that gap would otherwise let a batch issued for the previous project run
    /// against the newly opened one, rewriting files the user never searched.
    /// Pinning closes exactly that window; the mid-batch re-checks close the rest.
    ///
    /// A mismatch returns `ReplaceSummary(abandoned: true)` — zeroed counts, but
    /// **not** an empty summary — for the same reason the mid-batch bail does: the
    /// view then says the batch stopped because the folder changed, rather than
    /// the misleading "no file matched". Nothing has run at this point, so there
    /// is nothing to count; `abandoned` alone carries the message.
    ///
    /// The `nil` default is never rejected: an unpinned call makes no claim about
    /// which project it was issued for, so it is judged only by the results it
    /// holds (the path direct calls and the tests take).
    public func replaceAll(template: String, originGeneration: Int? = nil) async -> ReplaceSummary {
        if let originGeneration, originGeneration != rootGeneration {
            return ReplaceSummary(abandoned: true)
        }

        let token = rootGeneration
        let snapshot = results
        // `resultsQuery`, not `query`: the two are equal unless a caller binds a
        // live field to the settable public `query`, and re-matching the captured
        // ranges against a pattern nothing was searched with would fail the
        // staleness check for every file — a batch that reports "everything
        // skipped" about a current result list.
        let query = resultsQuery
        guard !snapshot.isEmpty else { return ReplaceSummary() }

        let service = fileService
        let byteCap = maxFileBytes
        var summary = ReplaceSummary()

        for result in snapshot {
            guard token == rootGeneration else {
                summary.abandoned = true
                return summary
            }

            if let buffer = bufferText(for: result.fileURL) {
                let outcome = await offMain {
                    Self.replacedText(
                        in: buffer,
                        captured: result.matches,
                        query: query,
                        template: template
                    )
                }
                guard token == rootGeneration else {
                    summary.abandoned = true
                    return summary
                }
                guard let outcome else {
                    summary.filesSkipped += 1
                    continue
                }
                // Re-read the buffer *after* the hop, for exactly the reason the
                // disk branch re-reads inside it: the editor stays live while the
                // batch runs, so text typed during the suspension would be
                // silently overwritten by the replacement computed from the older
                // buffer. A buffer that moved is skipped and counted, not
                // clobbered — the same rule the on-disk staleness check applies.
                guard bufferText(for: result.fileURL) == buffer else {
                    summary.filesSkipped += 1
                    continue
                }
                if applyBufferText(result.fileURL, outcome.text) {
                    summary.filesChanged += 1
                    summary.matchesReplaced += outcome.count
                } else {
                    summary.errors.append(
                        "\(result.relativePath): couldn't update the open editor."
                    )
                }
            } else {
                let outcome = await offMain {
                    Self.replaceOnDisk(
                        result: result,
                        query: query,
                        template: template,
                        fileService: service,
                        maxBytes: byteCap
                    )
                }
                // The outcome is folded in *before* the token check, unlike the
                // buffer branch above: this file's write already happened inside
                // the hop, so a switch that lands now must still report it (and
                // reconcile a tab opened during it). Bailing first would leave a
                // written file uncounted — the caller gates its Local Changes and
                // tree refresh on `filesChanged > 0`, so the tree would keep
                // showing pre-replacement content.
                switch outcome {
                case let .written(count, original, replaced):
                    summary.filesChanged += 1
                    summary.matchesReplaced += count
                    reconcileBufferOpenedDuringWrite(
                        url: result.fileURL,
                        original: original,
                        replaced: replaced
                    )
                case .skipped:
                    summary.filesSkipped += 1
                case let .failed(reason):
                    summary.errors.append("\(result.relativePath): \(reason)")
                }
                guard token == rootGeneration else {
                    summary.abandoned = true
                    return summary
                }
            }
        }

        return summary
    }

    /// Hand the replaced text to a tab that **opened on `url` while the write was
    /// in flight**, so the editor never shows content the batch has superseded.
    ///
    /// The buffer-vs-disk branch is chosen before the file's off-main hop, so a
    /// file with no tab at that instant goes down the disk path — and the editor
    /// stays live, so the user can open that very file while its
    /// read-modify-write runs. Such a tab read the *pre-replacement* text and is
    /// **clean**, so nothing would ever correct it: it would contradict disk
    /// silently until a save wrote the stale text back over the replacement. This
    /// puts it exactly where the buffer branch would have — changed in the tab,
    /// left for the user to save (what the confirmation promises for open files).
    ///
    /// Only while it still holds precisely what was on disk, for the same reason
    /// the buffer branch re-reads after its own hop: a buffer that has already
    /// moved on (opened *and* typed into inside that window) is left alone rather
    /// than clobbered.
    private func reconcileBufferOpenedDuringWrite(url: URL, original: String, replaced: String) {
        guard let buffer = bufferText(for: url), buffer == original else { return }
        _ = applyBufferText(url, replaced)
    }

    /// What one on-disk file's replacement did, so the main actor can count it
    /// without the I/O ever crossing back.
    ///
    /// `.written` carries the text on both sides of the write, not just the count:
    /// the main actor needs them to recognise — and correct — a tab that opened on
    /// the file mid-write (see `reconcileBufferOpenedDuringWrite`). Both are the
    /// strings the hop already held, and they are dropped as soon as the file's
    /// iteration ends, so at most one file's contents is retained at a time.
    enum DiskReplaceOutcome: Equatable {
        case written(count: Int, original: String, replaced: String)
        /// The file no longer matches the captured results, or the service now
        /// declines to hand over its text (it became binary or oversize).
        case skipped
        case failed(String)
    }

    /// Read `result`'s file, re-match it against the captured hits, and write the
    /// replaced text back. Runs entirely off the main actor.
    nonisolated static func replaceOnDisk(
        result: FileSearchResult,
        query: SearchQuery,
        template: String,
        fileService: FileServicing,
        maxBytes: Int
    ) -> DiskReplaceOutcome {
        do {
            guard let contents = try fileService.readTextIfNotBinary(url: result.fileURL, maxBytes: maxBytes) else {
                return .skipped
            }
            guard let outcome = replacedText(
                in: contents,
                captured: result.matches,
                query: query,
                template: template
            ) else { return .skipped }

            try fileService.write(outcome.text, to: result.fileURL)
            return .written(count: outcome.count, original: contents, replaced: outcome.text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `text` with `captured`'s matches replaced, or `nil` when `text` no longer
    /// carries them (see `replaceAll`'s staleness rule).
    ///
    /// The plan is built from the *fresh* scan, so a regex template's group
    /// references resolve against the text actually on disk, and applied
    /// last-to-first — `replacePlan`'s ordering guarantee, which is what lets a
    /// length-changing replacement run over one mutable buffer without any offset
    /// bookkeeping.
    nonisolated static func replacedText(
        in text: String,
        captured: [SearchMatch],
        query: SearchQuery,
        template: String
    ) -> (text: String, count: Int)? {
        guard !captured.isEmpty else { return nil }
        let string = text as NSString
        guard let fresh = try? TextSearchEngine.matches(in: string, query: query),
              Array(fresh.prefix(captured.count)) == captured
        else { return nil }

        let plan = TextSearchEngine.replacePlan(
            matches: Array(fresh.prefix(captured.count)),
            in: string,
            query: query,
            template: template
        )
        guard !plan.isEmpty else { return nil }

        let mutable = NSMutableString(string: text)
        for edit in plan {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return (text: mutable as String, count: plan.count)
    }

    /// Run `work` on the private serial queue and resume with its result — the
    /// `GitCLIService.run(_:in:)` shape, so blocking file I/O never lands on the
    /// main thread while the model itself stays `@MainActor`.
    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Open buffers

    /// The unsaved text of the open tab naming `url`, from a **freshly taken**
    /// snapshot, or `nil` when no tab does.
    ///
    /// Replace All calls this per file on purpose: the editor stays live while
    /// the batch runs, so a tab opened (or edited) mid-batch must be seen rather
    /// than written to disk behind the editor's back. Its cost is one resolution
    /// per open tab plus one for `url` — the same `openFiles.first { canonical
    /// … }` scan the workspace itself would do, and bounded by the *matched*
    /// files rather than by the whole project, which is why the search path
    /// (which walks every file) snapshots once instead.
    private func bufferText(for url: URL) -> String? {
        let buffers = openBuffers()
        guard !buffers.isEmpty else { return nil }
        return Self.bufferIndex(buffers)[Self.bufferKey(for: url)]
    }

    /// A snapshot of the open tabs re-keyed by canonical path, so a candidate is
    /// matched with a single dictionary hit.
    ///
    /// The key is `CanonicalPath.canonical(_:).path` — the very transform
    /// `WorkspaceModel.fileID(forURL:)` compares tabs with, so a tab opened
    /// through a symlink, through `/private/tmp` vs `/tmp`, or with `.`/`..`
    /// components still matches the file the traversal produced. Two tabs that
    /// canonicalize to one path keep one entry, as `fileID(forURL:)`'s `first`
    /// does (the workspace refuses to open the same file twice anyway).
    nonisolated static func bufferIndex(_ buffers: [URL: String]) -> [String: String] {
        var index: [String: String] = [:]
        index.reserveCapacity(buffers.count)
        for (url, text) in buffers { index[bufferKey(for: url)] = text }
        return index
    }

    /// The `bufferIndex` key for one file URL.
    nonisolated static func bufferKey(for url: URL) -> String {
        CanonicalPath.canonical(url).path
    }

    // MARK: - Pure helpers

    /// The file-mask globs, split on commas (and whitespace, so `*.ts, *.tsx`
    /// behaves as typed). An empty result means "every file".
    nonisolated public static func maskPatterns(_ mask: String) -> [String] {
        mask.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Whether a file *name* passes the mask — `ProjectFileWalk.matchesMask`,
    /// kept under this name because the mask is a search concept the walk merely
    /// applies.
    nonisolated public static func matchesMask(name: String, patterns: [String]) -> Bool {
        ProjectFileWalk.matchesMask(name: name, patterns: patterns)
    }

    /// Every file under `root` worth searching — `ProjectFileWalk.collectFiles`,
    /// which the symbol index walks the project with as well, so a file one of
    /// them declines to read is invisible to the other too.
    nonisolated static func collectFiles(
        root: URL,
        maskPatterns: [String],
        fileService: FileServicing
    ) -> [URL] {
        ProjectFileWalk.collectFiles(root: root, maskPatterns: maskPatterns, fileService: fileService)
    }

    /// Search one batch of files, preferring an open buffer's text over the
    /// file's on-disk contents. Files with no match, unreadable files, and the
    /// ones `readTextIfNotBinary` rejects (binary/oversize) simply produce no
    /// entry.
    ///
    /// `matchBudget` bounds how many matches the whole chunk may *materialize*,
    /// and is a memory guard rather than a second cap: the caller's own
    /// `maxMatches` clipping is what decides what the user sees. Without it a
    /// one-character query would build every match — and, far more expensively,
    /// its ~300-unit `MatchPreview` — for all `chunkSize` files before a single
    /// one was clipped, so a chunk holding a few megabyte-scale files (a lock
    /// file, a minified bundle, generated code) allocated hundreds of megabytes
    /// of previews only to throw nearly all of them away. The caller passes
    /// `remaining + 1`, one *over* what it can still accept, so the surplus
    /// match keeps its existing `> remaining` overflow test — and with it the
    /// `truncated` flag — working unchanged.
    nonisolated static func searchChunk(
        files: [URL],
        buffers: [String: String],
        root: URL,
        query: SearchQuery,
        fileService: FileServicing,
        maxBytes: Int,
        matchBudget: Int
    ) -> [FileSearchResult] {
        var remaining = matchBudget
        var results: [FileSearchResult] = []

        for url in files {
            guard remaining > 0 else { break }

            let contents: String?
            // With no tabs open there is nothing to match against, so the
            // canonicalization — the one per-file symlink resolution this path
            // costs — is skipped outright for the common fresh-project case.
            if let buffer = buffers.isEmpty ? nil : buffers[bufferKey(for: url)] {
                contents = buffer
            } else {
                contents = (try? fileService.readTextIfNotBinary(url: url, maxBytes: maxBytes)) ?? nil
            }
            guard let contents else { continue }

            let text = contents as NSString
            guard let found = try? TextSearchEngine.matches(in: text, query: query),
                  !found.isEmpty
            else { continue }

            let matches = found.count > remaining ? Array(found.prefix(remaining)) : found
            remaining -= matches.count

            results.append(
                FileSearchResult(
                    fileURL: url,
                    relativePath: relativePath(of: url, under: root),
                    matches: matches,
                    previews: matches.map { preview(for: $0, in: text) }
                )
            )
        }

        return results
    }

    /// `url`'s path below `root` — `ProjectFileWalk.relativePath(of:under:)`, so
    /// a result row and a definition-picker row spell the same file identically.
    nonisolated static func relativePath(of url: URL, under root: URL) -> String {
        ProjectFileWalk.relativePath(of: url, under: root)
    }

    /// The clipped line around `match`, plus the match's range inside it.
    ///
    /// Line boundaries come from `NSString.getLineStart(_:end:contentsEnd:for:)`,
    /// so the same Unicode separators the gutter and `LineStartIndex` use apply
    /// (CRLF is one break), and `contentsEnd` is what keeps the separator out of
    /// the preview.
    nonisolated static func preview(for match: SearchMatch, in text: NSString) -> MatchPreview {
        let location = min(max(match.range.location, 0), text.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: location, length: 0)
        )

        let windowStart = max(lineStart, location - previewLead)
        let windowEnd = min(contentsEnd, windowStart + previewWindow)
        guard windowEnd > windowStart else {
            return MatchPreview(text: "", matchRange: NSRange(location: 0, length: 0))
        }

        let window = NSRange(location: windowStart, length: windowEnd - windowStart)
        let start = min(max(location - windowStart, 0), window.length)
        let end = min(max(NSMaxRange(match.range) - windowStart, start), window.length)
        return MatchPreview(
            text: text.substring(with: window),
            matchRange: NSRange(location: start, length: end - start)
        )
    }
}
