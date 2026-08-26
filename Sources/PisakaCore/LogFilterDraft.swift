import Foundation

/// The Log filter bar's editable draft, shared by the macOS bar and the iOS
/// advanced-filter form.
///
/// Why this type exists: the Log filter bar used to mirror `LogFilter`'s
/// dimensions into seven separate `@State` properties and re-assembled a fresh
/// `LogFilter` on every toggle/date-picker change via `.onChange`. Seeding
/// those `@State` values from a model-published `filter` then masqueraded as a
/// user edit — every seed called `onApplyFilter`, which published a new
/// `filter`, which seeded again. Value-equality suppression of that echo failed
/// whenever two applies interleaved, because the published `filter` lags the
/// latest `requestedFilter` by one phase, so an echo built from the published
/// value is genuinely different and accepted.
///
/// This draft is the structural cure: it is the single editable value a
/// **user-intent binding** writes. The binding's `set` stores the mutated draft
/// into `@State` *and* applies it by passing the new value explicitly to
/// `onApplyFilter`. Seeding the view assigns the draft directly and therefore
/// cannot reach the apply path — no equality check is involved anywhere. The
/// draft also owns the trimming, the day-boundary normalization and the verbatim
/// ref preservation that the old `applyFilter` lost.
public struct LogFilterDraft: Equatable {
    /// The ref scope, carried verbatim — never re-resolved against the known
    /// refs. The display mapping (`displayRefTag`) is separate, so an apply
    /// fired while `references` is still empty still emits `.ref(name)` while
    /// the picker shows "All".
    public var refSelection: LogFilter.RefSelection
    /// Author text as typed, verbatim/untrimmed. Trimmed only when assembling
    /// a `LogFilter`.
    public var author: String
    /// Path text as typed, verbatim/untrimmed. Trimmed only when assembling a
    /// `LogFilter`.
    public var path: String
    public var sinceEnabled: Bool
    public var since: Date
    public var untilEnabled: Bool
    public var until: Date

    /// Sentinel picker tag meaning "all refs" (`--all`).
    public static let allRefsTag = ""

    public init(
        refSelection: LogFilter.RefSelection = .all,
        author: String = "",
        path: String = "",
        sinceEnabled: Bool = false,
        since: Date = Date(),
        untilEnabled: Bool = false,
        until: Date = Date()
    ) {
        self.refSelection = refSelection
        self.author = author
        self.path = path
        self.sinceEnabled = sinceEnabled
        self.since = since
        self.untilEnabled = untilEnabled
        self.until = until
    }

    /// Seed every dimension from `filter`, parking a disabled date picker on
    /// `defaultDate`.
    ///
    /// A `nil` bound disables its toggle and parks the picker on `defaultDate`;
    /// a present bound is seeded verbatim. The inclusive last-second-of-day
    /// instant for `until` is still on the selected day, so `filter(calendar:)`
    /// re-derives the same bound — the round-trip is idempotent and needs no
    /// inverse, as `since`'s start-of-day already is.
    public init(filter: LogFilter, defaultDate: Date) {
        refSelection = filter.refSelection
        author = filter.author ?? ""
        path = filter.path ?? ""
        sinceEnabled = filter.since != nil
        since = filter.since ?? defaultDate
        untilEnabled = filter.until != nil
        until = filter.until ?? defaultDate
    }

    /// Assemble the server-side `LogFilter` this draft represents.
    ///
    /// - Trims `author`/`path` (blank → `nil`).
    /// - Normalizes `since` to the start of the selected day and `until` to the
    ///   last second of the selected day (git's `--until` is inclusive).
    /// - Carries `refSelection` through verbatim — never re-resolved against the
    ///   known refs.
    public func filter(calendar: Calendar = .current) -> LogFilter {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return LogFilter(
            refSelection: refSelection,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor,
            since: sinceEnabled ? calendar.startOfDay(for: since) : nil,
            until: untilEnabled ? Self.endOfDay(of: until, calendar: calendar) : nil,
            path: trimmedPath.isEmpty ? nil : trimmedPath
        )
    }

    /// The picker's display tag for this draft, resolving via
    /// `LogFilter.resolvedRef(amongKnown:)` and mapping `nil` ("all") onto
    /// `allRefsTag`. Use only for the picker's `get`; the write path keeps the
    /// verbatim `refSelection`.
    public func displayRefTag(amongKnown references: [String]) -> String {
        let probe = LogFilter(refSelection: refSelection)
        return probe.resolvedRef(amongKnown: references) ?? Self.allRefsTag
    }

    /// Update `refSelection` from a picker tag: empty tag → `.all`, otherwise
    /// `.ref(tag)`. The complement of `displayRefTag(amongKnown:)`.
    public mutating func selectRef(tag: String) {
        if tag.isEmpty {
            refSelection = .all
        } else {
            refSelection = .ref(tag)
        }
    }

    private static func endOfDay(of date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return date }
        return next.addingTimeInterval(-1)
    }
}
