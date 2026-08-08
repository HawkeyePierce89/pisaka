import Foundation

/// The project's symbol store: per-file symbol arrays plus the two lookup
/// buckets everything above it asks questions through — *"who is named X"*
/// (go-to-definition) and *"who could the typed text be reaching for"*
/// (autocompletion, literal prefix or fuzzy alike).
///
/// A value type on purpose. `SymbolIndexModel` mutates a working copy off the
/// main actor and publishes snapshots, so the reader
/// (`SymbolIntelligenceProvider`, on the main actor, between keystrokes) never
/// sees a half-updated store and never needs a lock.
///
/// **Files are keyed by `CanonicalPath.canonical(_:).path`** — the same key
/// `ProjectSearchModel.bufferKey(for:)` uses — so the traversal's spelling of a
/// file and a tab opened through a symlink (or through `/private/tmp` vs
/// `/tmp`) collapse to one entry instead of double-indexing the file and
/// offering every symbol in it twice.
///
/// **This type ranks nothing.** Every lookup here *filters and orders*; none of
/// them scores. That holds for the fuzzy and member lookups too: they ask
/// `FuzzyMatch` whether a candidate matches at all and throw the match quality
/// away, returning candidates in a stable, documented order (file key, then
/// location within the file, then name). Every relevance decision —
/// current-file first, case-sensitive prefix before case-insensitive, the
/// receiver's own container first, symbols before keywords before bare words —
/// belongs to `SymbolIntelligenceProvider`. Keeping the two apart is what lets
/// the ranking rules be tested exhaustively without building an index, and what
/// lets the phase-2 LSP provider reuse the ranking with a different source of
/// truth.
public struct SymbolIndex: Equatable, Sendable {

    /// One stored symbol together with the file key it was filed under, so the
    /// buckets can be filtered and sorted without recanonicalizing a URL per
    /// comparison (`canonical(_:)` touches the file system).
    private struct Entry: Equatable, Sendable {
        let fileKey: String
        let symbol: Symbol
    }

    /// File key → that file's symbols, in extraction order.
    private var files: [String: [Symbol]] = [:]
    /// Exact, case-sensitive name → every entry declaring it.
    private var nameBucket: [String: [Entry]] = [:]
    /// Lowercased **word-boundary initial** → every entry whose name has a word
    /// starting with it (`ArrayBuffer` is filed under both `a` and `b`).
    ///
    /// A coarse bucket by design: it turns a completion query into a scan of one
    /// small slice rather than of the whole project, and it costs one array per
    /// distinct initial letter instead of one per distinct prefix (which is what
    /// a full prefix trie/multimap would cost, for a lookup that is already fast
    /// enough at this granularity).
    ///
    /// Filing a name under every boundary rather than only under its first
    /// character is what makes fuzzy lookup affordable: `symbols(matching:)`
    /// still reads exactly *one* bucket — the one its first typed character
    /// names — and that bucket provably holds every candidate `FuzzyMatch` could
    /// accept, because the matcher requires the first matched character to land
    /// on a word boundary. The price is bounded and paid in both directions:
    /// `FuzzyMatch.maximumInitials` caps a name at 8 keys, and hand-written code
    /// averages two or three, so both the stored entries and the entries scanned
    /// per keystroke grow by that same small factor rather than by the size of
    /// the project.
    private var initialBucket: [Character: [Entry]] = [:]

    public init() {}

    // MARK: - Mutation

    /// Replace everything the index knows about `fileURL` with `symbols`.
    ///
    /// Idempotent and total for that file: calling it twice leaves no residue of
    /// the first call in either bucket, which is what makes a re-index after an
    /// edit safe to run as often as the debounce fires.
    public mutating func replace(fileURL: URL, symbols: [Symbol]) {
        replace(fileKey: Self.fileKey(for: fileURL), symbols: symbols)
    }

    /// The same replacement, by the key the file is to be **filed under**.
    ///
    /// The one a caller that already holds the key must use, and for the same two
    /// reasons `remove(fileKey:)` states: `fileKey(for:)` resolves symlinks
    /// against the file system, so re-deriving it here would put one such round
    /// trip per indexed file on whichever actor is publishing — and it could
    /// answer a *different* string than the one the caller's own bookkeeping
    /// (`indexedFiles`, `stamps`) recorded when it walked the file, which would
    /// file the entry under a key no later removal looks for.
    public mutating func replace(fileKey key: String, symbols: [Symbol]) {
        purge(fileKey: key)
        files[key] = symbols
        for symbol in symbols {
            let entry = Entry(fileKey: key, symbol: symbol)
            nameBucket[symbol.name, default: []].append(entry)
            for initial in FuzzyMatch.wordBoundaryInitials(of: symbol.name) {
                initialBucket[initial, default: []].append(entry)
            }
        }
    }

    /// Forget a file entirely — used when the traversal no longer sees it
    /// (deleted, renamed, or newly gitignored).
    public mutating func remove(fileURL: URL) {
        remove(fileKey: Self.fileKey(for: fileURL))
    }

    /// The same removal, by the key the file was **filed under**.
    ///
    /// The one a caller that already holds the key must use, and removal is
    /// exactly where that matters: `fileKey(for:)` resolves symlinks against the
    /// file system, so re-deriving it from the URL of a file that has just been
    /// deleted can answer a different string than the one the entry was stored
    /// under — and the removal would then quietly purge nothing, leaving the
    /// vanished file's symbols answering go-to-definition until the folder was
    /// reopened. It also saves a syscall per removed file.
    public mutating func remove(fileKey key: String) {
        purge(fileKey: key)
        files[key] = nil
    }

    /// Drop every bucket entry belonging to `fileKey`.
    ///
    /// Only the buckets the file actually contributed to are touched (its
    /// symbols name them), so the cost is proportional to the *index's* share of
    /// those buckets and not to the size of the whole index.
    ///
    /// **One sweep per distinct bucket, not per symbol.**
    /// `initialBucket[initial]` holds the entries of the entire project for that
    /// letter, so a per-symbol loop would scan it end to end once for every
    /// symbol in the file — and, if the entry were bound with `var` while the
    /// dictionary still referenced it, copy it that many times too. A 500-symbol
    /// file touches at most a couple of dozen distinct initials, so collecting
    /// the distinct names and initials first turns a re-index (which fires every
    /// debounce tick while the user types in that file) from hundreds of
    /// full-bucket passes into one each. The removals go through
    /// `dict[key]?.removeAll` rather than a `var` binding, which mutates the
    /// stored array in place instead of copying it.
    ///
    /// The initials are collected with the very function `replace` filed them
    /// under, so a name that contributed several keys (`ArrayBuffer` → `a`, `b`)
    /// is swept out of *all* of them: deriving them any other way here would
    /// leave a hump-keyed entry behind and let a deleted symbol keep answering
    /// completion.
    private mutating func purge(fileKey key: String) {
        guard let previous = files[key] else { return }

        var names = Set<String>()
        var initials = Set<Character>()
        for symbol in previous {
            names.insert(symbol.name)
            initials.formUnion(FuzzyMatch.wordBoundaryInitials(of: symbol.name))
        }

        for name in names {
            nameBucket[name]?.removeAll { $0.fileKey == key }
            if nameBucket[name]?.isEmpty == true { nameBucket[name] = nil }
        }
        for initial in initials {
            initialBucket[initial]?.removeAll { $0.fileKey == key }
            if initialBucket[initial]?.isEmpty == true { initialBucket[initial] = nil }
        }
    }

    // MARK: - Lookup

    /// Every symbol declaring exactly `name`, case-sensitively.
    ///
    /// Case-sensitive because this answers go-to-definition, where `Foo` and
    /// `foo` are different declarations in every language the editor indexes.
    /// An empty name yields nothing.
    public func symbols(named name: String) -> [Symbol] {
        guard !name.isEmpty else { return [] }
        return Self.ordered(nameBucket[name] ?? [])
    }

    /// Every symbol `query` could be reaching for — a literal prefix
    /// (case-sensitively or not) *or* a fuzzy/camelCase subsequence — capped at
    /// `limit` after ordering.
    ///
    /// A superset of the prefix lookup this replaced, not a different rule:
    /// `arr` still finds `ArrayBuffer`, and now `aBu` and `buf` do too.
    /// `FuzzyMatch` owns what counts as a match; this method only asks. That is
    /// also why the answer needs exactly one bucket: the matcher requires the
    /// first matched character to sit on a word boundary, and every boundary of
    /// every name is a bucket key, so the bucket named by the query's first
    /// character already contains every candidate that could possibly match.
    ///
    /// The cap is applied to the *ordered* result, so it is deterministic rather
    /// than "whichever matches were stored first". An empty query yields
    /// nothing: with nothing typed there is nothing to complete, and returning
    /// the whole project would only push the truncation decision up a layer.
    /// (Member completion's typed dot is the one case where an empty query is
    /// meaningful, and it asks `members(matching:limit:)` instead — where the
    /// candidate set is bounded by the member kinds rather than by the query.)
    public func symbols(matching query: String, limit: Int) -> [Symbol] {
        guard !query.isEmpty, limit > 0, let initial = Self.initial(of: query) else { return [] }
        let matches = (initialBucket[initial] ?? []).filter {
            FuzzyMatch.matches($0.symbol.name, query: query)
        }
        return Array(Self.ordered(matches).prefix(limit))
    }

    /// Every *member* — a `.method`, `.property` or `.constant` that names an
    /// enclosing type — matching `query`, capped at `limit`.
    ///
    /// **An empty query matches every member.** That is the typed-dot case: the
    /// user has committed to a member access and typed nothing after it, so the
    /// candidate set is bounded by the kind filter rather than by the text, and
    /// the cap is what keeps it finite. Every other lookup here treats an empty
    /// query as "nothing to complete"; this one cannot, and the difference is
    /// the whole reason it is a separate method.
    ///
    /// Container-less symbols are excluded even when their kind qualifies: a
    /// `.constant` declared at file scope is not reachable through a dot, and
    /// offering it after one would be a worse answer than offering nothing.
    ///
    /// **No index structure backs this** — it is one ordered pass over the
    /// per-file storage, stopping at `limit`. It runs at most once per typed
    /// dot, behind the editor's completion debounce and off the main actor,
    /// while ordinary per-keystroke completion never takes this path; a
    /// by-container bucket would therefore cost memory on every keystroke to
    /// speed up the one request that can afford to be linear.
    public func members(matching query: String, limit: Int) -> [Symbol] {
        guard limit > 0 else { return [] }

        var found: [Symbol] = []
        for key in files.keys.sorted() {
            for symbol in files[key] ?? [] where Self.isMember(symbol) {
                guard query.isEmpty || FuzzyMatch.matches(symbol.name, query: query) else { continue }
                found.append(symbol)
                if found.count == limit { return found }
            }
        }
        return found
    }

    /// Every member declared in the container spelled exactly `name`, uncapped.
    ///
    /// Case-**sensitive**: this answers "the receiver is spelled `Worker`, which
    /// members belong to `Worker`", and a type name that differs only in case is
    /// a different type in every language the editor indexes — the same reason
    /// `symbols(named:)` is case-sensitive. Uncapped because one type's member
    /// list is small by construction, and truncating it is what would make the
    /// receiver's own members — the ones ranked first — go missing.
    public func members(inContainer name: String) -> [Symbol] {
        guard !name.isEmpty else { return [] }

        var found: [Symbol] = []
        for key in files.keys.sorted() {
            for symbol in files[key] ?? [] where Self.isMember(symbol) && symbol.containerName == name {
                found.append(symbol)
            }
        }
        return found
    }

    /// Whether the project declares a **type** named exactly `name` — the one
    /// question the receiver heuristic asks before it promotes a container's own
    /// members.
    ///
    /// Deliberately not "declares anything named `name`": a function called
    /// `worker` says nothing about what `worker.` will offer, and promoting an
    /// unrelated container that happens to share the spelling would be worse
    /// than promoting nothing.
    public func declaresType(named name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return nameBucket[name]?.contains { $0.symbol.kind == .type } ?? false
    }

    /// The symbols of one file, in extraction order (i.e. source order).
    public func symbols(inFile fileURL: URL) -> [Symbol] {
        files[Self.fileKey(for: fileURL)] ?? []
    }

    /// How many files currently contribute to the index. A file that was walked
    /// and yielded no symbols still counts: it is indexed, just empty.
    public var indexedFileCount: Int { files.count }

    /// Whether the index holds no files at all — the state after
    /// `prepareForFolderChange`, before the first chunk lands.
    public var isEmpty: Bool { files.isEmpty }

    // MARK: - Keying and ordering

    /// The storage key for a file URL: see the type's note on canonical keying.
    public static func fileKey(for url: URL) -> String {
        CanonicalPath.canonical(url).path
    }

    /// The bucket character a *query* is looked up under: its first character,
    /// lowercased. Multi-scalar lowercasing (`İ`) can widen a character, so the
    /// first character of the lowercased string is taken rather than the
    /// lowercased first character — which is exactly what
    /// `FuzzyMatch.wordBoundaryInitials(of:)` does when it files a name, so both
    /// sides of the lookup agree.
    private static func initial(of name: String) -> Character? {
        name.lowercased().first
    }

    /// Whether a symbol is reachable through a dot: a kind that hangs off a type
    /// *and* an actual container to hang off. Both halves are load-bearing —
    /// see `members(matching:limit:)` on why a container-less constant is not a
    /// member.
    private static func isMember(_ symbol: Symbol) -> Bool {
        switch symbol.kind {
        case .method, .property, .constant:
            return !(symbol.containerName ?? "").isEmpty
        default:
            return false
        }
    }

    /// The documented stable order: file key, then position in the file, then
    /// name. Deterministic regardless of the order files were indexed in, which
    /// is what keeps a rebuilt index from reshuffling a menu under the user.
    private static func ordered(_ entries: [Entry]) -> [Symbol] {
        entries.sorted { lhs, rhs in
            if lhs.fileKey != rhs.fileKey { return lhs.fileKey < rhs.fileKey }
            if lhs.symbol.range.location != rhs.symbol.range.location {
                return lhs.symbol.range.location < rhs.symbol.range.location
            }
            return lhs.symbol.name < rhs.symbol.name
        }.map(\.symbol)
    }
}
