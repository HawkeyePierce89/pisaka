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

    /// - Parameters:
    ///   - provider: the code-intelligence seam, read at each question rather
    ///     than held, because the app swaps a routing provider in once the LSP
    ///     layer is up (`SymbolIndexController.installProvider`) and a model that
    ///     captured the old one would keep asking it forever. `nil` — no provider
    ///     installed — is not an error: it simply means the textual answer is the
    ///     only one available.
    ///   - openBuffers: the *unsaved* text of every open tab that has a URL, keyed
    ///     by that URL, called on the main actor **once** per textual scan. A
    ///     tab's text is scanned instead of the file on disk, so the rows describe
    ///     what the user is looking at. A url-less buffer names no file and is
    ///     left out.
    public init(
        fileService: FileServicing = FileService(),
        provider: @escaping () -> CodeIntelligenceProviding? = { nil },
        openBuffers: @escaping () -> [URL: String] = { [:] },
        maxFileBytes: Int = FindUsagesModel.defaultMaxFileBytes
    ) {
        self.fileService = fileService
        self.provider = provider
        self.openBuffers = openBuffers
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
    @discardableResult
    public func prepareForQuery() -> Int {
        generation += 1
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
    public func clearIfNaming(_ oldName: String) {
        guard identifier == oldName, !oldName.isEmpty else { return }
        generation += 1
        clearState(reason: .noQuery)
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

        let semantic = await provider()?.references(for: usages) ?? []
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
    /// stops the moment one row more than the cap is in hand: the surplus row is
    /// what sets `isTruncated` through `UsagesAnswer.make`'s own `> cap` test, and
    /// walking on past it would read the rest of the project to build rows the cap
    /// discards.
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
                    requestingFile: usages.fileURL
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
                requestingFile: usages.fileURL
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
