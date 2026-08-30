import Foundation

/// One file's worth of usage rows, in the order the panel draws them.
///
/// A *run* of the ordered answer rather than a re-grouping of it: `UsagesAnswer
/// .make` has already put the requesting file first and everything after it in
/// path order, so every file's rows are already adjacent and grouping is a walk
/// that never re-sorts. Doing it the other way — bucketing by URL and sorting the
/// buckets — would quietly re-derive an ordering the answer already decided, and
/// would put the requesting file back in the alphabet.
///
/// The grouping key is the file *URL*, not `relativePath`: two files can display
/// the same relative path (a row outside the project root shows its file name),
/// and merging those would draw one header over two different files.
public struct UsageFileGroup: Equatable, Sendable {
    /// The file every row in this group is in.
    public let fileURL: URL
    /// The path the group header shows — the rows' own `relativePath`, which they
    /// all share by construction.
    public let relativePath: String
    /// The rows, in answer order.
    public let rows: [UsageResult]

    public init(fileURL: URL, relativePath: String, rows: [UsageResult]) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.rows = rows
    }

    /// Consecutive runs of `rows` sharing a file, in the order they arrive.
    public static func grouped(_ rows: [UsageResult]) -> [UsageFileGroup] {
        var groups: [UsageFileGroup] = []
        var currentURL: URL?
        var current: [UsageResult] = []

        func flush() {
            guard let currentURL, let first = current.first else { return }
            groups.append(
                UsageFileGroup(fileURL: currentURL, relativePath: first.relativePath, rows: current)
            )
            current = []
        }

        for row in rows {
            if row.fileURL != currentURL {
                flush()
                currentURL = row.fileURL
            }
            current.append(row)
        }
        flush()
        return groups
    }
}

/// Why the panel has no rows to draw — the sentence it prints instead of a list.
///
/// A panel showing nothing must say *which* nothing it means. "Ask a question"
/// and "I asked and there is genuinely nothing" look identical as an empty list
/// and mean opposite things, and the third case — a caret that resolved no name —
/// is the one where the command did not run at all.
public enum UsagesEmptyReason: Equatable, Sendable {
    /// Nothing has been asked yet (or the last answer was cleared).
    case noQuery
    /// The caret resolved something that is not an identifier, so there was no
    /// word to look for. `TextualUsageScanner` refuses such a query too, and for
    /// the same reason: it cannot occur as a whole word.
    case notAnIdentifier
    /// The question was asked and answered, and the answer is empty.
    case noUsages
}

/// The Find Usages panel's state: what was asked, what came back, what it means,
/// and whether the walk is still running.
///
/// `ProjectSearchModel`'s shape throughout — an `@MainActor ObservableObject`
/// whose I/O is injected behind `FileServicing`, whose file traversal is the
/// shared `ProjectFileWalk`, whose off-main work runs on a private serial queue,
/// and whose overlapping requests are ordered by a generation token captured
/// **synchronously** before any `Task` hop. Foundation only: the provider arrives
/// as a closure, so Core never learns where one comes from.
///
/// **The two answers, and why only this type knows about the second one.** The
/// intelligence seam's `references` is LSP-or-nothing (hover's rule): an index of
/// declarations cannot enumerate references, so a provider with nothing to say
/// says `[]` rather than reaching for a weaker answer. The weaker answer exists
/// all the same — `TextualUsageScanner`'s whole-word scan — but it costs a walk of
/// the whole project, and putting a project walk inside the provider chain would
/// make every unserved ⌃⌘U a traversal disguised as a protocol call (decision 1).
/// So the fallback is a *model* decision, taken here, where the walk, the file
/// service and the open buffers already live, and the panel is told which of the
/// two it is holding (`UsageProvenance`).
///
/// **Where the work runs.** The walk and every chunk's read+scan go to the serial
/// queue; only the published state is touched on the main actor. The open buffers
/// are therefore snapshotted **once**, before the walk, exactly as the project
/// search snapshots them: the closure reads the workspace and so must run on the
/// main actor, and matching a candidate against the open tabs costs a symlink
/// resolution per tab. Rows are published per chunk, so a long walk fills the
/// panel as it goes, and the request token is re-checked after *every* `await` —
/// a superseded question drops its partial rows rather than interleaving them
/// with the newer one's.
@MainActor
public final class FindUsagesModel: ObservableObject {
    // `nonisolated` for `ProjectSearchModel`'s reason: the `nonisolated static`
    // helpers and the `init` default arguments read these from outside the main
    // actor.

    /// The largest file the textual scan will read — the project search's number,
    /// referenced rather than restated so the two walks decline exactly the same
    /// files.
    public nonisolated static let defaultMaxFileBytes = ProjectSearchModel.defaultMaxFileBytes

    /// How many files one off-main batch scans before publishing — the project
    /// search's number, for the same reason.
    nonisolated static let chunkSize = ProjectSearchModel.chunkSize

    /// The identifier the rows are about, or `""` when nothing has been asked.
    /// The panel header's subject, and what `clearIfNaming(_:)` compares.
    @Published public private(set) var identifier = ""

    /// The rows, grouped by file in answer order.
    @Published public private(set) var groups: [UsageFileGroup] = []

    /// What the rows mean, or `nil` when there are none. Never inferred from the
    /// rows themselves — an empty semantic answer and an empty textual one are
    /// both "no usages", and neither is a claim worth labelling.
    @Published public private(set) var provenance: UsageProvenance?

    /// Whether the cap clipped the list (`UsagesAnswer.cap`).
    @Published public private(set) var isTruncated = false

    /// `true` from the moment a question is asked until it is answered or
    /// superseded.
    @Published public private(set) var isSearching = false

    /// Why there is nothing to draw, or `nil` while there are rows.
    @Published public private(set) var emptyReason: UsagesEmptyReason? = .noQuery

    /// Every row, ungrouped — what a test asserts on and what a caller iterating
    /// the answer wants.
    public var rows: [UsageResult] { groups.flatMap(\.rows) }

    private let fileService: FileServicing
    private let provider: () -> CodeIntelligenceProviding?
    private let openBuffers: () -> [URL: String]
    private let serverTexts: () -> [URL: String]
    private let maxFileBytes: Int

    /// Serial, so the walk and every chunk run one after another off the main
    /// thread (and an injected stub is never touched concurrently).
    private let queue = DispatchQueue(label: "ws.karmanov.pisaka.find-usages", qos: .userInitiated)

    /// Monotonically increasing token identifying the latest *question*. Bumped
    /// by `find`, by `prepareForFolderChange` and by `clearIfNaming`; a running
    /// search publishes only while its captured token is still the latest.
    private var generation = 0

    /// Monotonically increasing token identifying the *project* the rows belong
    /// to, bumped only when the opened folder actually changes.
    ///
    /// The two tokens answer different questions and are checked for different
    /// purposes: the request token says "a newer question was asked", and gates
    /// what may be **published**; the project token says "the files this walk is
    /// reading belong to a folder the user has left", and gates whether the walk
    /// **continues at all**. A folder switch moves both, so either would stop the
    /// walk today — but only the project token expresses "abandon the work",
    /// which is what must stay true if a future caller ever re-asks the same
    /// question without changing projects.
    private var rootGeneration = 0

    /// The folder last searched or prepared for, so `prepareForFolderChange` can
    /// tell a genuine switch from a repeat call.
    private var lastRoot: URL?

    /// The identifier of the question whose token `prepareForQuery(for:)` last
    /// reserved and whose `find` has not started yet, or `nil` when no reserved
    /// question is outstanding.
    ///
    /// **What `identifier` cannot answer.** A question is reserved on the main
    /// actor and asked one `Task` hop later, and `identifier` only becomes the
    /// question's own subject once that hop lands — until then it still names the
    /// *previous* answer (or nothing at all). `clearIfNaming` comparing only
    /// `identifier` would therefore read a rename that arrives inside that window
    /// as being about some other name, leave the reserved token alone, and let the
    /// queued walk publish rows for the spelling the rename has just removed —
    /// precisely the state decision 7 exists to prevent. Held here so the reserved
    /// question can be invalidated by name before it has a chance to run.
    private var pendingIdentifier: String?

    /// - Parameters:
    ///   - provider: the code-intelligence seam, read at each question rather
    ///     than held, because the app swaps a routing provider in once the LSP
    ///     layer is up (`SymbolIndexController.installProvider`) and a model that
    ///     captured the old one would keep asking it forever. `nil` — no provider
    ///     installed — is not an error: it simply means the textual answer is the
    ///     only one available.
    ///   - openBuffers: the *unsaved* text of every open tab that has a URL, keyed
    ///     by that URL, called on the main actor when the **textual** walk runs.
    ///     A tab's text is used instead of the file on disk there, so the rows
    ///     describe what the user is looking at. A url-less buffer names no file
    ///     and is left out. Deliberately *not* the semantic half's source — see
    ///     `serverTexts`.
    ///   - serverTexts: the text each open document was last **pushed to a
    ///     language server** as, keyed by file URL, called on the main actor when
    ///     the semantic question is asked. This and `openBuffers` differ, and the
    ///     difference is the whole reason there are two seams: a background tab
    ///     typed in less than the document-sync debounce ago is a buffer no server
    ///     has seen, so mapping that server's `(line, character)` answers onto it
    ///     produces a row with a plausible line number, a preview drawn from the
    ///     wrong offsets, and a reveal that then refuses the range — a row that is
    ///     wrong rather than absent, which is exactly what `UsagesRequest
    ///     .openTexts` exists to prevent. The rename path closes the identical
    ///     hazard with the identical snapshot (`LSPWorkspace.lastSentTexts()`).
    ///     A file this map does not name is one no server holds open, which means
    ///     the server answered about the bytes on **disk** — so the fallback there
    ///     is the disk and never a buffer. Empty by default: a caller with no
    ///     language server has no semantic answer to map.
    public init(
        fileService: FileServicing = FileService(),
        provider: @escaping () -> CodeIntelligenceProviding? = { nil },
        openBuffers: @escaping () -> [URL: String] = { [:] },
        serverTexts: @escaping () -> [URL: String] = { [:] },
        maxFileBytes: Int = FindUsagesModel.defaultMaxFileBytes
    ) {
        self.fileService = fileService
        self.provider = provider
        self.openBuffers = openBuffers
        self.serverTexts = serverTexts
        self.maxFileBytes = maxFileBytes
    }

    // MARK: - Generation

    /// Synchronously record that the project is switching to `root` (`nil` when
    /// the folder was closed), returning the request generation the switch
    /// produced.
    ///
    /// `LocalChangesModel.prepareForFolderChange`'s precedent and its reason: the
    /// app calls this in the same main-actor turn that handles the folder open,
    /// *before* spawning any `Task`, so an in-flight walk resumes to find itself
    /// superseded rather than publishing the previous project's files into the new
    /// one's window. The rows are cleared up front too — a usage list belongs to
    /// the project it was asked in, and leaving it clickable across a switch would
    /// open files the window no longer shows. A repeat call for the same folder is
    /// a no-op.
    @discardableResult
    public func prepareForFolderChange(root: URL?) -> Int {
        guard root != lastRoot else { return generation }
        lastRoot = root
        generation += 1
        rootGeneration += 1
        pendingIdentifier = nil
        clearState(reason: .noQuery)
        return generation
    }

    /// Synchronously reserve the token for a question that is about to be asked
    /// across a `Task` hop, and hand it back for `find`'s `request:`.
    ///
    /// **Reserving is what makes the token mean anything.** A caller that merely
    /// *read* the current generation would give two rapid ⌃⌘U presses the same
    /// token, and whichever task happened to start first would then supersede the
    /// other — including when the loser is the later question, which is the exact
    /// outcome the token exists to prevent. Bumping here orders the presses in the
    /// main-actor turn that handles them, which is the only place their order is
    /// known.
    ///
    /// The identifier is taken along with the token because a reserved question
    /// is a question this model is already committed to publishing and yet cannot
    /// name — see `pendingIdentifier`, which is what lets `clearIfNaming` reach a
    /// query a rename has invalidated before it ever ran.
    @discardableResult
    public func prepareForQuery(for identifier: String) -> Int {
        generation += 1
        pendingIdentifier = identifier
        return generation
    }

    /// The current request generation — what `prepareForQuery()` last handed out.
    public var currentRequestGeneration: Int { generation }

    /// The current project generation — the token a folder switch moves.
    public var currentRootGeneration: Int { rootGeneration }

    /// Drop the results when they are about the identifier `oldName`, leaving an
    /// answer about any other name alone (decision 7).
    ///
    /// Called after a rename lands. Deliberately a *clear* rather than a re-run:
    /// re-asking would spend a server round trip or a whole project walk on a
    /// question nobody asked again, and every row already on screen names a symbol
    /// that no longer exists under that spelling — so the honest state after a
    /// rename is no state. The generation is bumped along with it, so a walk still
    /// in flight for the old name cannot publish rows over the cleared panel.
    ///
    /// **A question that has been reserved but has not started counts as naming
    /// the old name too** (`pendingIdentifier`): a ⌃⌘U pressed while the rename's
    /// round trip was in flight holds a token this model handed out, and nothing
    /// about it has reached `identifier` yet, so comparing the displayed subject
    /// alone would let that queued walk publish the old spelling *after* the
    /// rename removed it. Invalidating the token is the whole of what that case
    /// needs — the rows on screen still describe whatever they described, so the
    /// clear stays conditional on the displayed subject and an answer about
    /// another name survives a rename either way.
    ///
    /// **A reservation for another name survives too, and that is what the bump
    /// is conditional on.** The bump exists to strand a walk in flight *for the
    /// old name*; but a standing reservation already holds the current token, so
    /// any such walk was superseded the moment `prepareForQuery` handed that
    /// token out and there is nothing left for a second bump to strand. Bumping
    /// anyway would land on the one thing that *is* current — the newer,
    /// unrelated question — and reject it at `find`'s guard, which is the reverse
    /// of what the token is for. So the bump runs only when no reservation stands
    /// (`nil`) or the standing one is itself about `oldName`.
    ///
    /// **Invalidating also has to end the panel's loading state, which is not the
    /// same act as clearing the displayed subject.** `isSearching` is only ever
    /// true for a search whose token this model still expects someone to redeem,
    /// and the reservation this call retires is exactly the redeemer: a walk for
    /// some *other* name that a `prepareForQuery(for: oldName)` had already
    /// superseded was going to be replaced on screen by that reserved question's
    /// own `find` — which now returns at its guard instead. With nobody left to
    /// set the flag down, the panel would say "Searching…" forever over rows from
    /// a walk that was abandoned mid-flight. Those rows are a partial answer by
    /// construction (`isSearching` is false the instant one settles), so the
    /// honest state is the same one a folder switch leaves: no query.
    public func clearIfNaming(_ oldName: String) {
        guard !oldName.isEmpty else { return }
        let showsOldName = identifier == oldName
        let awaitsOldName = pendingIdentifier == oldName
        guard showsOldName || awaitsOldName else { return }
        let invalidates = pendingIdentifier == nil || awaitsOldName
        if invalidates {
            generation += 1
            pendingIdentifier = nil
        }
        if showsOldName || (invalidates && isSearching) { clearState(reason: .noQuery) }
    }

    // MARK: - Finding

    /// Answer "where is this used" for the identifier in `request`: the provider
    /// first, the textual scan when it says nothing.
    ///
    /// `root` is the opened folder, and `nil` is legitimate rather than an error:
    /// a single file opened on its own has no project to walk, so the textual scan
    /// falls back to the requesting buffer alone — one file's usages honestly
    /// labelled is a better answer than an empty panel for a command the user just
    /// invoked.
    ///
    /// A `request` token a newer question has already superseded is rejected
    /// before any work — `LocalChangesModel.refresh(root:requestGeneration:)`'s
    /// rule, because unstructured `Task`s are not guaranteed to start in creation
    /// order. The token is the one `prepareForQuery()` reserved, and it is *not*
    /// bumped again here: the reservation already ordered the presses, and bumping
    /// a second time would let the task that merely started first win.
    public func find(_ usages: UsagesRequest, root: URL?, request: Int? = nil) async {
        let token: Int
        if let request {
            guard request == generation else { return }
            token = request
        } else {
            generation += 1
            token = generation
        }
        // The reservation has been redeemed: from here `identifier` names this
        // question itself, so a `pendingIdentifier` left standing would only let
        // `clearIfNaming` invalidate a token that has already been spent. (An
        // unreserved `find` bumped past every reservation just above, which
        // retires them for the same reason.)
        pendingIdentifier = nil
        // The root a question is asked about is recorded here as well as in
        // `prepareForFolderChange` — `ProjectSearchModel.search`'s rule, for its
        // reason: the model must not depend on having been *told* about a folder
        // to know which one its rows belong to, or a root that arrived some other
        // way leaves `lastRoot` stale and the later "the folder closed" call reads
        // as a repeat of a switch that never happened.
        if root != lastRoot { rootGeneration += 1 }
        lastRoot = root
        let projectToken = rootGeneration

        guard IdentifierScanner.isIdentifier(usages.identifier) else {
            identifier = usages.identifier
            clearState(reason: .notAnIdentifier, keepingIdentifier: true)
            return
        }

        identifier = usages.identifier
        groups = []
        provenance = nil
        isTruncated = false
        emptyReason = nil
        isSearching = true

        // The documents the server has travel with the question, for
        // `UsagesRequest.openTexts`'s reason: a server's ranges in a dirty
        // background tab are that tab's coordinates, not disk's. `serverTexts`
        // rather than `openBuffers` because the coordinate space is the one the
        // server was *told about*, which a buffer typed in since the last push
        // definitionally is not (see the seam's own note). Enriched here rather
        // than at the call site so no caret command has to know which of the two
        // answers needs it — and read on the main actor, where the seam must run.
        let semanticRequest = UsagesRequest(
            identifier: usages.identifier,
            fileURL: usages.fileURL,
            offset: usages.offset,
            text: usages.text,
            openTexts: usages.openTexts.isEmpty ? serverTexts() : usages.openTexts
        )
        let semantic = await provider()?.references(for: semanticRequest) ?? []
        guard token == generation else { return }

        if !semantic.isEmpty {
            publish(
                UsagesAnswer.make(
                    identifier: usages.identifier,
                    rows: semantic,
                    provenance: .semantic,
                    requestingFile: usages.fileURL
                )
            )
            isSearching = false
            return
        }

        await scanTextually(usages, root: root, token: token, projectToken: projectToken)
    }

    /// The second answer: every whole-word occurrence of the identifier in the
    /// project's readable text files.
    ///
    /// Published per chunk, so the panel fills as the walk proceeds. Collection
    /// stops the moment one row more than the cap is in hand — walking on past it
    /// would read the rest of the project to build rows the cap discards — and the
    /// walk tells `make` it stopped (`stoppedEarly`) rather than leaving it to
    /// infer truncation from a row count that has since been deduplicated.
    private func scanTextually(
        _ usages: UsagesRequest,
        root: URL?,
        token: Int,
        projectToken: Int
    ) async {
        guard let root else {
            publishTextualForRequestingBufferAlone(usages)
            isSearching = false
            return
        }

        let service = fileService
        let byteCap = maxFileBytes
        let name = usages.identifier
        // One main-actor read of the workspace for the whole scan, canonicalized
        // off-main: see the type's "Where the work runs" note.
        let buffers = openBuffers()

        let (walked, bufferIndex) = await offMain {
            (
                ProjectFileWalk.collectFiles(root: root, maskPatterns: [], fileService: service),
                ProjectSearchModel.bufferIndex(buffers)
            )
        }
        guard token == generation, projectToken == rootGeneration else { return }

        // **The file the question was asked from is always scanned**, even when
        // the walk does not yield it. It need not: a tab may hold a file the
        // project's `.gitignore` excludes, or one opened from outside the root
        // entirely, and neither is a file `ProjectFileWalk` visits. Without this
        // the panel would answer "No usages" for a name the caret is sitting on —
        // a demonstrably false answer, and the one case where the user can see it
        // is false. It leads the list for `UsagesAnswer.make`'s reason.
        //
        // The comparison is a plain path test rather than a canonical one on
        // purpose: canonicalizing every walked file resolves a symlink per file
        // across the whole project, and the cost of getting it wrong is nil —
        // scanning a file twice through the same `scanChunk` produces byte-identical
        // rows, which `make`'s canonical dedup collapses.
        var files = walked
        if let fileURL = usages.fileURL {
            let requesting = fileURL.standardizedFileURL
            if !files.contains(where: { $0.standardizedFileURL.path == requesting.path }) {
                files.insert(requesting, at: 0)
            }
        }

        var collected: [UsageResult] = []
        var index = 0
        // One memo for the whole walk, not one per `make` call: see
        // `CanonicalPathMemo`. Every chunk that finds something re-runs the
        // hygiene over everything collected so far, and each of those resolves a
        // symlink per distinct file — on the main actor — so a per-call cache
        // would make the streaming publish quadratic in the very projects it
        // exists for.
        let paths = CanonicalPathMemo()

        while index < files.count && collected.count <= UsagesAnswer.cap {
            let end = min(index + Self.chunkSize, files.count)
            let chunk = Array(files[index..<end])
            index = end

            let found = await offMain {
                Self.scanChunk(
                    files: chunk,
                    buffers: bufferIndex,
                    root: root,
                    identifier: name,
                    fileService: service,
                    maxBytes: byteCap
                )
            }
            guard token == generation, projectToken == rootGeneration else { return }

            // A chunk that found nothing changes no row, and `make` is not free:
            // it re-deduplicates and re-sorts everything collected so far, and
            // resolves a symlink per distinct file while doing it. Most chunks of
            // most projects contain no occurrence at all, so republishing an
            // unchanged list for each of them is the walk's whole cost for
            // nothing.
            guard !found.isEmpty else { continue }
            collected.append(contentsOf: found)
            publish(
                UsagesAnswer.make(
                    identifier: name,
                    rows: collected,
                    provenance: .textual,
                    requestingFile: usages.fileURL,
                    stoppedEarly: index < files.count && collected.count > UsagesAnswer.cap,
                    paths: paths
                )
            )
        }

        // **The walk always ends in an answer**, including the two cases the loop
        // above cannot publish from: a project whose walk yielded no file at all
        // (an unreadable root, or one where everything is excluded), and one where
        // no chunk matched. Without this the terminal state would be `provenance`
        // and `emptyReason` both `nil` — which the panel draws as "nothing has
        // been asked yet", the one conflation `UsagesEmptyReason` exists to
        // prevent, for a question the user just asked and this walk just answered.
        publish(
            UsagesAnswer.make(
                identifier: name,
                rows: collected,
                provenance: .textual,
                requestingFile: usages.fileURL,
                // **Files left unread is truncation, whatever the row count says.**
                // The loop stops on the *raw* count passing the cap while `make`
                // measures the *deduplicated* one, and the two disagree by
                // construction: the requesting file is inserted at index 0 whenever
                // the walk spells it differently, so its rows are collected twice
                // and collapse here. Left to infer truncation from its own count,
                // `make` would then call a list built from part of the project
                // complete — the one guarantee the cap makes, broken exactly when
                // it bites.
                stoppedEarly: index < files.count,
                paths: paths
            )
        )
        isSearching = false
    }

    /// The no-project case: scan the buffer the question came from and nothing
    /// else. A url-less buffer names no file a row could open, so it answers
    /// nothing at all.
    private func publishTextualForRequestingBufferAlone(_ usages: UsagesRequest) {
        guard let fileURL = usages.fileURL else {
            publish(
                UsagesAnswer(
                    identifier: usages.identifier,
                    rows: [],
                    provenance: .textual,
                    isTruncated: false
                )
            )
            return
        }
        let rows = Self.rows(
            in: usages.text as NSString,
            of: usages.identifier,
            fileURL: fileURL,
            root: nil
        )
        publish(
            UsagesAnswer.make(
                identifier: usages.identifier,
                rows: rows,
                provenance: .textual,
                requestingFile: fileURL
            )
        )
    }

    // MARK: - Publishing

    private func publish(_ answer: UsagesAnswer) {
        identifier = answer.identifier
        groups = UsageFileGroup.grouped(answer.rows)
        provenance = answer.provenance
        isTruncated = answer.isTruncated
        emptyReason = answer.isEmpty ? .noUsages : nil
    }

    /// Everything but the identifier, which a caller may want to keep on screen
    /// (the refused-query case names the word it refused).
    private func clearState(reason: UsagesEmptyReason, keepingIdentifier: Bool = false) {
        if !keepingIdentifier { identifier = "" }
        groups = []
        provenance = nil
        isTruncated = false
        isSearching = false
        emptyReason = reason
    }

    /// Run `work` on the private serial queue and resume with its result — the
    /// `ProjectSearchModel.offMain` shape, so blocking file I/O never lands on the
    /// main thread while the model itself stays `@MainActor`.
    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Pure helpers

    /// Scan one batch of files, preferring an open buffer's text over the file's
    /// on-disk contents. Files with no occurrence, unreadable files and the ones
    /// `readTextIfNotBinary` rejects (binary/oversize) simply produce no row.
    nonisolated static func scanChunk(
        files: [URL],
        buffers: [String: String],
        root: URL,
        identifier: String,
        fileService: FileServicing,
        maxBytes: Int
    ) -> [UsageResult] {
        var found: [UsageResult] = []

        for url in files {
            let contents: String?
            // With no tabs open there is nothing to prefer, so the per-file
            // symlink resolution is skipped outright for the common case.
            if let buffer = buffers.isEmpty ? nil : buffers[ProjectSearchModel.bufferKey(for: url)] {
                contents = buffer
            } else {
                contents = (try? fileService.readTextIfNotBinary(url: url, maxBytes: maxBytes)) ?? nil
            }
            guard let contents else { continue }

            found.append(
                contentsOf: rows(in: contents as NSString, of: identifier, fileURL: url, root: root)
            )
        }

        return found
    }

    /// One text's whole-word occurrences as panel rows.
    nonisolated static func rows(
        in text: NSString,
        of identifier: String,
        fileURL: URL,
        root: URL?
    ) -> [UsageResult] {
        let relativePath = ProjectFileWalk.relativePath(of: fileURL, under: root)
        return TextualUsageScanner.matches(of: identifier, in: text).map { match in
            UsageResult(
                fileURL: fileURL,
                range: match.range,
                line: match.line,
                relativePath: relativePath,
                preview: match.preview,
                isTextual: true
            )
        }
    }
}
