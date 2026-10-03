import Foundation

/// The Log's date column: a commit's author date said relative to now.
///
/// `Commit.date` is git's raw strict ISO-8601 `%aI` string; this parses it and
/// answers, in the order the cases are tried:
/// - `just now` under a minute (and for a date up to a minute in the future —
///   two machines' clocks rarely agree to the second);
/// - `Nm ago` under an hour, even across midnight;
/// - `Nh ago` on the same calendar day;
/// - `Yesterday` on the previous calendar day;
/// - `N days ago` two to six calendar days back;
/// - otherwise a short date, `MMM d`, plus `, yyyy` when the year is not
///   now's — which is also what a date more than a minute in the future gets,
///   since no relative phrase describes it honestly.
///
/// Calendar days are the injected calendar's, in its time zone; the short date
/// is formatted in the injected locale. Input that does not parse is returned
/// unchanged, so the column never blanks.
public enum RelativeCommitDate {
    /// The instant a raw `%aI` string names, or `nil` when it does not parse.
    public static func date(from raw: String) -> Date? {
        try? Date.ISO8601FormatStyle().parse(raw)
    }

    /// The relative text for `raw` as seen at `now`.
    public static func text(for raw: String, now: Date, calendar: Calendar, locale: Locale) -> String {
        guard let date = date(from: raw) else { return raw }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -60 {
            return shortDate(date, now: now, calendar: calendar, locale: locale)
        }
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case 0: return "\(Int(elapsed / 3600))h ago"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        default: return shortDate(date, now: now, calendar: calendar, locale: locale)
        }
    }

    /// `MMM d`, plus `, yyyy` when `date` falls in another year than `now`.
    ///
    /// A format style rather than a `DateFormatter`: a Log row redraws on every
    /// hover change and most of a real history lands here, and Foundation
    /// caches the formatter a style resolves to where a `DateFormatter` would be
    /// built and configured afresh per row per redraw.
    private static func shortDate(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let format: Date.FormatString = sameYear
            ? "\(month: .abbreviated) \(day: .defaultDigits)"
            : "\(month: .abbreviated) \(day: .defaultDigits), \(year: .defaultDigits)"
        return date.formatted(
            Date.VerbatimFormatStyle(format: format, locale: locale, timeZone: calendar.timeZone, calendar: calendar)
        )
    }
}
