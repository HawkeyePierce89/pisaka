import Foundation

/// The recently-searched queries, newest first — **one** list shared by the find
/// bar and Find in Files, because the engine behind them is one and so is the
/// question "what did I search for".
///
/// An entry is a whole `SearchQuery`, not a string: the three toggles are part
/// of what was searched for, and a pattern picked back without them would run a
/// different search than the one it is offering to repeat.
///
/// ## The one recording rule
///
/// `record(_:)` is the only way an entry enters, and it decides everything:
///
/// - A pattern that is empty or whitespace-only once trimmed is **refused
///   outright**. Blankness is judged here and nowhere else, so no surface has to
///   restate the test before recording (`TextSearchError.emptyPattern` reads an
///   empty field the same way: "no query", not a search for spaces).
/// - An entry whose pattern matches one already held — compared **exactly**,
///   case-sensitively and untrimmed, since two patterns differing only in case
///   find different things under `Aa` and are two searches — removes the older
///   value and inserts the new one at the front, so the **newer flags win**.
/// - The list is then truncated to `capacity`, dropping the oldest.
///
/// "No change" is expressed as an **unchanged value**, never as a return flag:
/// this type is `Equatable`, and `SettingsStore`'s writer compares the next
/// value against the held one to decide whether to publish at all. A flag would
/// be a second spelling of the same fact, and the one the caller could ignore.
///
/// ## Persistence
///
/// The whole list is one JSON `Data` value, encoded from the file-private
/// `SearchQueryHistoryEntry` DTO below rather than from `SearchQuery` — which
/// deliberately stays non-`Codable`, so no property rename in the search engine
/// can silently change what is on disk.
///
/// **Failure is whole-value, not per-entry**, which is the deliberate opposite
/// of `SettingsStore.lspServerConsent`'s element-by-element read. A consent map
/// that drops one unreadable entry costs one server its answer and nothing else;
/// a history that drops *some* entries is a list whose absences the user cannot
/// see and therefore cannot trust. So anything short of a fully readable array
/// reads back as an empty history.
///
/// The invariants are enforced on **read** as well as on write:
/// `init(persistedData:)` and `init(entries:)` both replay their input
/// oldest-first through `record(_:)`, so a stored blank, a duplicate or an
/// over-long list — from an older build, a hand-edited domain, anywhere — reads
/// back as a list this type could itself have produced.
public struct SearchQueryHistory: Equatable {
    /// How many queries are remembered. The oldest fall off the end.
    public static let capacity = 20

    /// The remembered queries, **newest first**. Patterns are unique by the
    /// recording rule, which is what lets a menu key its rows on the pattern.
    public private(set) var entries: [SearchQuery]

    /// An empty history — what a fresh install and every decode failure read as.
    public init() {
        entries = []
    }

    /// Whether nothing has been recorded. The menu is disabled on this.
    public var isEmpty: Bool { entries.isEmpty }

    /// Build a history from a newest-first list, replaying it oldest-first
    /// through `record(_:)` so blanks, duplicates and over-long lists cannot
    /// enter by this door either.
    public init(entries: [SearchQuery]) {
        self.entries = []
        for query in entries.reversed() {
            record(query)
        }
    }

    /// Record a query, by the one rule stated on the type.
    ///
    /// Callers record unconditionally: a blank pattern is refused here, so no
    /// surface tests one before calling.
    public mutating func record(_ query: SearchQuery) {
        guard !query.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        entries.removeAll { $0.pattern == query.pattern }
        entries.insert(query, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    /// Forget everything. What the menu's *Clear History* item does.
    public mutating func clear() {
        entries = []
    }

    // MARK: - Persistence

    /// Read a history back from its stored value.
    ///
    /// Every failure — the key absent, bytes that are not JSON, a JSON object
    /// where an array belongs, an element missing a key or mistyping one — is
    /// the same answer: an empty history. Never a partial one; see the type's
    /// doc comment for why this differs from the consent map on purpose.
    public init(persistedData: Data?) {
        guard let persistedData else {
            self.init()
            return
        }
        let decoded = try? JSONDecoder().decode([SearchQueryHistoryEntry].self, from: persistedData)
        guard let stored = decoded else {
            self.init()
            return
        }
        // Decoded newest-first, replayed through the one rule.
        self.init(entries: stored.map(\.query))
    }

    /// The value to store, or `nil` while the history is empty — so the store
    /// *removes* the key rather than writing an empty array, and "nothing
    /// recorded" keeps a single spelling on disk.
    public var persistedData: Data? {
        guard !entries.isEmpty else { return nil }
        return try? JSONEncoder().encode(entries.map(SearchQueryHistoryEntry.init))
    }

    // MARK: - Presentation

    /// The text of one menu row: the pattern, middle-truncated to at most
    /// `maxPatternLength` characters with a single `…`, followed by a
    /// space-separated suffix naming the flags that are on — `Aa`, `ab`, `.*`,
    /// in the toggles' own order.
    ///
    /// Decided here rather than left to a menu item's own truncation so the
    /// string is deterministic and can be asserted.
    public static func menuLabel(for query: SearchQuery, maxPatternLength: Int = 60) -> String {
        var label = truncatedMiddle(query.pattern, maxLength: maxPatternLength)
        if query.caseSensitive { label += " Aa" }
        if query.wholeWord { label += " ab" }
        if query.isRegex { label += " .*" }
        return label
    }

    /// `text` cut down to `maxLength` characters by removing its middle, with the
    /// single `…` counted against the budget — so the result is never longer
    /// than asked for.
    private static func truncatedMiddle(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        guard maxLength > 1 else { return "…" }

        let keep = maxLength - 1
        let headCount = (keep + 1) / 2
        let tailCount = keep - headCount
        let head = text.prefix(headCount)
        let tail = tailCount > 0 ? text.suffix(tailCount) : ""
        return "\(head)…\(tail)"
    }
}

/// The stored shape of one history entry, spelling its keys explicitly so the
/// on-disk encoding is this file's decision rather than a by-product of
/// `SearchQuery`'s property names — which is what keeps `SearchQuery` itself
/// free of any `Codable` conformance.
///
/// File-private and top-level rather than nested inside `SearchQueryHistory`:
/// it is the history's alone either way, and its `CodingKeys` — the whole reason
/// this type exists — would otherwise sit two levels deep, which the style
/// authority refuses and no in-file disable may buy back.
private struct SearchQueryHistoryEntry: Codable {
    var pattern: String
    var isRegex: Bool
    var caseSensitive: Bool
    var wholeWord: Bool

    private enum CodingKeys: String, CodingKey {
        case pattern
        case isRegex
        case caseSensitive
        case wholeWord
    }

    init(_ query: SearchQuery) {
        pattern = query.pattern
        isRegex = query.isRegex
        caseSensitive = query.caseSensitive
        wholeWord = query.wholeWord
    }

    var query: SearchQuery {
        SearchQuery(
            pattern: pattern,
            isRegex: isRegex,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord
        )
    }
}
