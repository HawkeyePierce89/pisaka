import Foundation

/// The project's symbol store: per-file symbol arrays plus the two lookup
/// buckets everything above it asks questions through — *"who is named X"*
/// (go-to-definition) and *"who starts with X"* (autocompletion).
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
/// **This type ranks nothing.** Lookups return candidates in a stable,
/// documented order (file key, then location within the file, then name), and
/// every relevance decision — current-file first, case-sensitive prefix before
/// case-insensitive, symbols before bare words — belongs to
/// `SymbolIntelligenceProvider`. Keeping the two apart is what lets the ranking
/// rules be tested exhaustively without building an index, and what lets the
/// phase-2 LSP provider reuse the ranking with a different source of truth.
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
    /// Lowercased first character → every entry whose name starts with it.
    ///
    /// A coarse bucket by design: it turns a prefix query into a scan of one
    /// small slice rather than of the whole project, and it costs one array per
    /// distinct initial letter instead of one per distinct prefix (which is what
    /// a full prefix trie/multimap would cost, for a lookup that is already fast
    /// enough at this granularity).
    private var prefixBucket: [Character: [Entry]] = [:]

    public init() {}

    // MARK: - Mutation

    /// Replace everything the index knows about `fileURL` with `symbols`.
    ///
    /// Idempotent and total for that file: calling it twice leaves no residue of
    /// the first call in either bucket, which is what makes a re-index after an
    /// edit safe to run as often as the debounce fires.
    public mutating func replace(fileURL: URL, symbols: [Symbol]) {
        let key = Self.fileKey(for: fileURL)
        purge(fileKey: key)
        files[key] = symbols
        for symbol in symbols {
            let entry = Entry(fileKey: key, symbol: symbol)
            nameBucket[symbol.name, default: []].append(entry)
            if let initial = Self.initial(of: symbol.name) {
                prefixBucket[initial, default: []].append(entry)
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
    /// **One sweep per distinct bucket, not per symbol.** `prefixBucket[initial]`
    /// holds the entries of the entire project for that letter, so a per-symbol
    /// loop would scan it end to end once for every symbol in the file — and, if
    /// the entry were bound with `var` while the dictionary still referenced it,
    /// copy it that many times too. A 500-symbol file touches at most a couple of
    /// dozen distinct initials, so collecting the distinct names and initials
    /// first turns a re-index (which fires every debounce tick while the user
    /// types in that file) from hundreds of full-bucket passes into one each.
    /// The removals go through `dict[key]?.removeAll` rather than a `var`
    /// binding, which mutates the stored array in place instead of copying it.
    private mutating func purge(fileKey key: String) {
        guard let previous = files[key] else { return }

        var names = Set<String>()
        var initials = Set<Character>()
        for symbol in previous {
            names.insert(symbol.name)
            if let initial = Self.initial(of: symbol.name) { initials.insert(initial) }
        }

        for name in names {
            nameBucket[name]?.removeAll { $0.fileKey == key }
            if nameBucket[name]?.isEmpty == true { nameBucket[name] = nil }
        }
        for initial in initials {
            prefixBucket[initial]?.removeAll { $0.fileKey == key }
            if prefixBucket[initial]?.isEmpty == true { prefixBucket[initial] = nil }
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

    /// Every symbol whose name starts with `prefix`, case-**in**sensitively,
    /// capped at `limit` after ordering.
    ///
    /// Case-insensitive because this answers completion, where typing `arr`
    /// should still offer `ArrayBuffer`. The cap is applied to the *ordered*
    /// result, so it is deterministic rather than "whichever matches were
    /// stored first". An empty prefix yields nothing: with nothing typed there
    /// is nothing to complete, and returning the whole project would only push
    /// the truncation decision up a layer.
    public func symbols(withPrefix prefix: String, limit: Int) -> [Symbol] {
        guard !prefix.isEmpty, limit > 0, let initial = Self.initial(of: prefix) else { return [] }
        let lowered = prefix.lowercased()
        let matches = (prefixBucket[initial] ?? []).filter {
            $0.symbol.name.lowercased().hasPrefix(lowered)
        }
        return Array(Self.ordered(matches).prefix(limit))
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

    /// The bucket character for a name: its first character, lowercased.
    /// Multi-scalar lowercasing (`İ`) can widen a character, so the first
    /// character of the lowercased string is taken rather than the lowercased
    /// first character — both sides of the comparison then agree.
    private static func initial(of name: String) -> Character? {
        name.lowercased().first
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
