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

    /// Seed a fresh draft from `filter`, parking a disabled date picker on
    /// `defaultDate`.
    ///
    /// This is the one case `seed(from:)` cannot serve on its own: a draft that
    /// does not exist yet has no day to preserve, so both pickers start on
    /// `defaultDate` and `seed(from:)` then overwrites whichever bound the
    /// filter states. The two forms are therefore one rule, not two that can
    /// drift.
    ///
    /// A present bound is seeded verbatim. The inclusive last-second-of-day
    /// instant for `until` is still on the selected day, so `filter(calendar:)`
    /// re-derives the same bound — the round-trip is idempotent and needs no
    /// inverse, as `since`'s start-of-day already is.
    public init(filter: LogFilter, defaultDate: Date) {
        self.init(sinceEnabled: false, since: defaultDate, untilEnabled: false, until: defaultDate)
        seed(from: filter)
    }

    /// Re-seed this draft from `filter`, keeping the day a disabled picker
    /// already shows.
    ///
    /// `refSelection`, `author`, `path` and both `…Enabled` flags are assigned
    /// verbatim — the ref especially, which is carried as published and never
    /// re-resolved against the known refs. Each **date** is assigned only when
    /// the incoming bound is present; an absent bound clears its flag and
    /// leaves the date already in the draft alone.
    ///
    /// Why the day is preserved: unticking a bound means "do not bound the log
    /// by this", not "forget the day I chose" — re-ticking it must offer that
    /// day back rather than jumping to now. And a seed is never a user edit: it
    /// is the view catching up to what the model published, so it may not
    /// discard a choice the user made and the filter simply has no room to
    /// carry. `init(filter:defaultDate:)` is the one caller with nothing to
    /// preserve, and it says so by parking both dates before seeding.
    public mutating func seed(from filter: LogFilter) {
        refSelection = filter.refSelection
        author = filter.author ?? ""
        path = filter.path ?? ""
        sinceEnabled = filter.since != nil
        if let incomingSince = filter.since { since = incomingSince }
        untilEnabled = filter.until != nil
        if let incomingUntil = filter.until { until = incomingUntil }
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
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return start }
        return next.addingTimeInterval(-1)
    }
}
