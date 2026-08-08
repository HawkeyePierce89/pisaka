import Foundation

/// The index-backed `CodeIntelligenceProviding` implementation — and the home of
/// **every ranking rule** in the feature.
///
/// `SymbolIndex` deliberately ranks nothing: its lookups return candidates in a
/// stable storage order. All relevance lives here, as `static` pure functions
/// over an index value, so each tie-break can be pinned by a test that builds
/// three symbols instead of a project. The instance methods are a thin async
/// shell over those functions, which is the whole protocol conformance.
///
/// The index is read through a closure rather than stored: `SymbolIndexModel`
/// publishes a fresh snapshot after every chunk, and a provider holding a stale
/// copy would answer from the state the folder was opened in.
///
/// **The read itself is `@MainActor`, the ranking is not.** The two methods below
/// are `nonisolated async`, so (SE-0338) their bodies run on the cooperative pool
/// rather than on the caller's actor — while the closures reach into a
/// `@MainActor` model that republishes `index` after every chunk of a walk.
/// Taking the snapshot inside a `MainActor.run` is what keeps a completion
/// request typed during an index build from reading the model's dictionaries
/// while `apply(_:)` is mutating them. Only the read hops: `SymbolIndex` is a
/// value type, so the ranking pass that follows walks a private copy off-main and
/// nothing can change under it.
public final class SymbolIntelligenceProvider: CodeIntelligenceProviding {

    /// How many completion items a caller is offered. AppKit's popup and the iOS
    /// accessory strip are both scroll-limited surfaces; beyond a couple of
    /// dozen entries the list stops being a choice and becomes a wall, and the
    /// user's next keystroke narrows it anyway.
    public static let defaultCompletionLimit = 30

    /// How many declarations a jump is allowed to disambiguate between.
    ///
    /// Both surfaces build one UI element per candidate — an `NSMenuItem` in
    /// `DefinitionPicker`, a `confirmationDialog` button on iOS — and neither
    /// bounds the list itself. The index is not only fed by languages with tidy
    /// declarations: `symbols.scm` also captures Markdown headings, top-level
    /// JSON/YAML keys and CSS selectors, so a docs-heavy or multi-package project
    /// can hold hundreds of declarations of `name`, `id` or `Overview`. Past a
    /// screenful the menu has stopped being a disambiguation anyway, and on iPhone
    /// a several-hundred-action sheet is a hang. Applied *after* ranking, so what
    /// survives is the best of them and not an arbitrary slice.
    public static let defaultDefinitionLimit = 50

    /// How many distinct words are harvested from the buffer per request. High
    /// enough that no hand-written file is truncated, low enough that a minified
    /// bundle cannot turn a debounce tick into a large allocation.
    public static let defaultBufferWordLimit = 5_000

    /// Both reads are `@Sendable @MainActor`: they are called from a
    /// `MainActor.run` inside a `nonisolated async` method, and the model they
    /// read is a `@MainActor` class (hence itself `Sendable`), so the annotation
    /// costs nothing and is what makes the hop expressible.
    private let index: @Sendable @MainActor () -> SymbolIndex
    private let projectRoot: @Sendable @MainActor () -> URL?
    private let completionLimit: Int
    private let bufferWordLimit: Int

    /// - Parameters:
    ///   - index: the current published snapshot; called once per request, on the
    ///     main actor.
    ///   - projectRoot: the opened folder, for the paths the picker shows.
    public init(
        index: @escaping @Sendable @MainActor () -> SymbolIndex,
        projectRoot: @escaping @Sendable @MainActor () -> URL?,
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        bufferWordLimit: Int = SymbolIntelligenceProvider.defaultBufferWordLimit
    ) {
        self.index = index
        self.projectRoot = projectRoot
        self.completionLimit = completionLimit
        self.bufferWordLimit = bufferWordLimit
    }

    /// Fixed-snapshot convenience, for tests and for a caller that has an index
    /// value rather than a model.
    public convenience init(
        index: SymbolIndex,
        projectRoot: URL? = nil,
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        bufferWordLimit: Int = SymbolIntelligenceProvider.defaultBufferWordLimit
    ) {
        self.init(
            index: { index },
            projectRoot: { projectRoot },
            completionLimit: completionLimit,
            bufferWordLimit: bufferWordLimit
        )
    }

    // MARK: - CodeIntelligenceProviding

    public func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] {
        let state = await snapshot()
        return Self.definitions(for: request, in: state.index, projectRoot: state.projectRoot)
    }

    public func completions(for request: CompletionRequest) async -> [CompletionItem] {
        let state = await snapshot()
        return Self.completions(
            for: request,
            in: state.index,
            limit: completionLimit,
            bufferWordLimit: bufferWordLimit
        )
    }

    /// Both reads in one main-actor hop — see the type's note on why the read is
    /// isolated and the ranking is not. One hop rather than two so a request
    /// cannot straddle a chunk publication and pair one walk's index with the
    /// next one's root.
    private func snapshot() async -> Snapshot {
        let readIndex = index
        let readRoot = projectRoot
        return await MainActor.run { Snapshot(index: readIndex(), projectRoot: readRoot()) }
    }

    private struct Snapshot: Sendable {
        let index: SymbolIndex
        let projectRoot: URL?
    }

    // MARK: - Definitions (pure)

    /// Declarations of `request.identifier`, ordered: **current file first**,
    /// then by relative path, line, and offset.
    ///
    /// The name match is *exact and case-sensitive* — `Worker` and `worker` are
    /// two declarations in every language the editor indexes, and offering both
    /// for a jump would make the picker appear where a direct navigation was
    /// unambiguous. Current-file-first because a name declared in the file being
    /// read is nearly always the one meant; the remaining order is path-then-line
    /// so a rebuilt index cannot reshuffle the menu under the user's cursor.
    ///
    /// An empty identifier yields nothing: it is what
    /// `IdentifierScanner.identifier(in:at:)` reports for a click on whitespace,
    /// and "no name" must beep rather than open an empty menu. More than `limit`
    /// declarations are truncated after ranking — see `defaultDefinitionLimit`.
    public static func definitions(
        for request: DefinitionRequest,
        in index: SymbolIndex,
        projectRoot: URL?,
        limit: Int = SymbolIntelligenceProvider.defaultDefinitionLimit
    ) -> [DefinitionCandidate] {
        guard !request.identifier.isEmpty, limit > 0 else { return [] }

        var keys = FileKeyCache()
        let currentKey = request.fileURL.map { keys.key(for: $0) }

        let candidates = index.symbols(named: request.identifier).map { symbol in
            (
                candidate: DefinitionCandidate(
                    symbol: symbol,
                    relativePath: relativePath(of: symbol.fileURL, under: projectRoot)
                ),
                isCurrentFile: currentKey != nil && keys.key(for: symbol.fileURL) == currentKey
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.isCurrentFile != rhs.isCurrentFile { return lhs.isCurrentFile }
            if lhs.candidate.relativePath != rhs.candidate.relativePath {
                return lhs.candidate.relativePath < rhs.candidate.relativePath
            }
            if lhs.candidate.symbol.line != rhs.candidate.symbol.line {
                return lhs.candidate.symbol.line < rhs.candidate.symbol.line
            }
            if lhs.candidate.symbol.range.location != rhs.candidate.symbol.range.location {
                return lhs.candidate.symbol.range.location < rhs.candidate.symbol.range.location
            }
            return lhs.candidate.symbol.name < rhs.candidate.symbol.name
        }.prefix(limit).map(\.candidate)
    }

    // MARK: - Completions (pure)

    /// Completion candidates for `request.prefix`: the index's prefix matches
    /// merged with the words the buffer itself contains, ranked, de-duplicated
    /// by name and capped at `limit`.
    ///
    /// **The ranking, in order** (each tie-break is pinned by its own test):
    ///
    /// 1. a **case-sensitive** prefix match before a merely case-insensitive one
    ///    — typing `arr` should still surface `ArrayBuffer`, but never above
    ///    `arrayCount`, because the user's capitalization is a signal;
    /// 2. the **current file** before the rest of the project — the nearby name
    ///    is the likely one, the same reasoning as go-to-definition;
    /// 3. a **known symbol** before a bare harvested word — a declaration is a
    ///    fact, a word is a guess, and the guess is only there so that languages
    ///    without a query still complete;
    /// 4. the **shorter** name — the shortest completion of a prefix is the most
    ///    common intent, and it is also the cheapest to correct if wrong;
    /// 5. lexicographic, then kind, purely so the list is deterministic: two
    ///    equally ranked entries must not swap places between two keystrokes.
    ///
    /// The typed token itself is dropped (completing `foo` to `foo` inserts
    /// nothing and hides a real candidate behind it), and duplicates collapse to
    /// their best-ranked entry, so a name that is both declared in this file and
    /// present in the buffer appears once, as the symbol.
    ///
    /// An empty prefix yields nothing — with nothing typed there is nothing to
    /// complete, and a popup listing the project would be noise.
    public static func completions(
        for request: CompletionRequest,
        in index: SymbolIndex,
        limit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        bufferWordLimit: Int = SymbolIntelligenceProvider.defaultBufferWordLimit
    ) -> [CompletionItem] {
        guard !request.prefix.isEmpty, limit > 0 else { return [] }

        var keys = FileKeyCache()
        let currentKey = request.fileURL.map { keys.key(for: $0) }
        let lowered = request.prefix.lowercased()

        // The index is asked for more than the cap: it orders by storage
        // position, so capping *there* at `limit` would hand the ranking an
        // arbitrary slice and the best candidate could be missing entirely.
        //
        // A generous multiple still is not a guarantee, and the one place that
        // matters is the current file: storage order is *by file key*, so in a
        // project with more prefix matches than the pre-cap, every match living
        // in a path sorting after the cut is invisible here — and whether the
        // file the user is typing in is one of them comes down to how its path
        // happens to sort. Ranking rule 2 (current file first) would then fail
        // exactly where it is most load-bearing. Asking that one file for its own
        // symbols costs a single dictionary hit and puts them back regardless of
        // where the pre-cap fell; the de-duplication below collapses the overlap
        // with whatever the bucket already returned.
        let symbols = index.symbols(withPrefix: request.prefix, limit: candidateLimit(for: limit))
            + (request.fileURL.map { index.symbols(inFile: $0) } ?? [])
                .filter { $0.name.lowercased().hasPrefix(lowered) }
        var ranked: [Ranked] = symbols.map { symbol in
            Ranked(
                item: CompletionItem(
                    text: symbol.name,
                    kind: symbol.kind,
                    isFromCurrentFile: currentKey != nil && keys.key(for: symbol.fileURL) == currentKey
                ),
                prefix: request.prefix
            )
        }

        let words = IdentifierScanner.words(in: request.text as NSString, limit: bufferWordLimit)
        for word in words where word.lowercased().hasPrefix(lowered) {
            // Harvested from the buffer being edited, so by definition local.
            ranked.append(
                Ranked(
                    item: CompletionItem(text: word, kind: nil, isFromCurrentFile: true),
                    prefix: request.prefix
                )
            )
        }

        var seen = Set<String>()
        var results: [CompletionItem] = []
        for entry in ranked.sorted(by: isOrderedBefore) {
            guard entry.item.text != request.prefix else { continue }
            guard seen.insert(entry.item.text).inserted else { continue }
            results.append(entry.item)
            if results.count == limit { break }
        }
        return results
    }

    /// How many index matches to rank before capping. A generous multiple of the
    /// visible cap, with a floor, so ranking has real choice without walking the
    /// whole project for a one-letter prefix.
    private static func candidateLimit(for limit: Int) -> Int {
        max(limit * 8, 200)
    }

    /// A candidate plus the precomputed ranking facts, so the comparator does no
    /// string work per comparison (`sorted` calls it O(n log n) times).
    private struct Ranked {
        let item: CompletionItem
        /// 0 when the candidate matches the typed prefix case-sensitively.
        let caseRank: Int
        /// 0 for the current file.
        let fileRank: Int
        /// 0 for a declared symbol, 1 for a harvested word.
        let sourceRank: Int
        /// UTF-16 length, the "shorter first" key.
        let length: Int

        init(item: CompletionItem, prefix: String) {
            self.item = item
            self.caseRank = item.text.hasPrefix(prefix) ? 0 : 1
            self.fileRank = item.isFromCurrentFile ? 0 : 1
            self.sourceRank = item.kind == nil ? 1 : 0
            self.length = item.text.utf16.count
        }
    }

    private static func isOrderedBefore(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
        if lhs.caseRank != rhs.caseRank { return lhs.caseRank < rhs.caseRank }
        if lhs.fileRank != rhs.fileRank { return lhs.fileRank < rhs.fileRank }
        if lhs.sourceRank != rhs.sourceRank { return lhs.sourceRank < rhs.sourceRank }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        if lhs.item.text != rhs.item.text { return lhs.item.text < rhs.item.text }
        // Same name, same rank, different kind: order by kind so which of the two
        // survives de-duplication is deterministic rather than sort-dependent.
        return (lhs.item.kind?.rawValue ?? "") < (rhs.item.kind?.rawValue ?? "")
    }

    // MARK: - Paths

    /// Memoized canonical file keys.
    ///
    /// `SymbolIndex.fileKey(for:)` resolves symlinks, i.e. it touches the file
    /// system. A completion pass compares hundreds of candidates against the
    /// current file on every debounce tick, and those candidates come from a
    /// handful of files, so memoizing by raw path bounds the resolutions to the
    /// number of *distinct* files instead of the number of symbols.
    private struct FileKeyCache {
        private var keys: [String: String] = [:]

        mutating func key(for url: URL) -> String {
            if let cached = keys[url.path] { return cached }
            let key = SymbolIndex.fileKey(for: url)
            keys[url.path] = key
            return key
        }
    }

    /// `url`'s path below `root` — what the definition picker shows.
    ///
    /// `ProjectFileWalk.relativePath(of:under:)`, the very helper Find in Files
    /// labels its result groups with: the URLs come from that same traversal, so
    /// a lexical strip is exact, and sharing the function is what keeps a
    /// definition row and a search row from spelling one file two ways.
    static func relativePath(of url: URL, under root: URL?) -> String {
        ProjectFileWalk.relativePath(of: url, under: root)
    }
}
