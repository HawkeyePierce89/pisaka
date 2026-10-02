import XCTest
@testable import PisakaCore

final class RelativeCommitDateTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Wednesday 2026-10-14 15:30:00 in Berlin (UTC+2 in October).
    private let now = try! Date.ISO8601FormatStyle().parse("2026-10-14T15:30:00+02:00")

    private func text(_ raw: String, now: Date? = nil) -> String {
        RelativeCommitDate.text(for: raw, now: now ?? self.now, calendar: calendar, locale: locale)
    }

    func testUnderAMinuteIsJustNow() {
        XCTAssertEqual(text("2026-10-14T15:30:00+02:00"), "just now")
        XCTAssertEqual(text("2026-10-14T15:29:01+02:00"), "just now")
    }

    func testMinutesUnderAnHour() {
        XCTAssertEqual(text("2026-10-14T15:29:00+02:00"), "1m ago")
        XCTAssertEqual(text("2026-10-14T14:30:01+02:00"), "59m ago")
    }

    func testHoursOnTheSameDay() {
        XCTAssertEqual(text("2026-10-14T14:30:00+02:00"), "1h ago")
        XCTAssertEqual(text("2026-10-14T00:00:00+02:00"), "15h ago")
    }

    func testThePreviousCalendarDayIsYesterday() {
        XCTAssertEqual(text("2026-10-13T23:59:59+02:00"), "Yesterday")
        XCTAssertEqual(text("2026-10-13T00:00:00+02:00"), "Yesterday")
    }

    func testTwoToSixDaysAgo() {
        XCTAssertEqual(text("2026-10-12T23:59:59+02:00"), "2 days ago")
        XCTAssertEqual(text("2026-10-08T00:00:00+02:00"), "6 days ago")
    }

    func testBeyondSixDaysIsAShortDate() {
        XCTAssertEqual(text("2026-10-07T23:59:59+02:00"), "Oct 7")
        XCTAssertEqual(text("2026-01-01T00:00:00+01:00"), "Jan 1")
    }

    func testAnotherYearCarriesTheYear() {
        XCTAssertEqual(text("2025-12-31T23:59:59+01:00"), "Dec 31, 2025")
    }

    func testTheOffsetIsReadAndDaysAreTheCalendarsOwn() {
        // 22:30 UTC on the 13th is 00:30 on the 14th in Berlin: the same day.
        XCTAssertEqual(text("2026-10-13T22:30:00Z"), "15h ago")
        // 21:59 UTC on the 13th is 23:59 on the 13th in Berlin: yesterday.
        XCTAssertEqual(text("2026-10-13T21:59:00Z"), "Yesterday")
    }

    func testMidnightCrossings() {
        let justAfterMidnight = try! Date.ISO8601FormatStyle().parse("2026-10-14T00:10:00+02:00")
        // Under an hour stays minutes, even across midnight.
        XCTAssertEqual(text("2026-10-13T23:50:00+02:00", now: justAfterMidnight), "20m ago")
        // Over an hour across midnight is the previous day, not hours.
        XCTAssertEqual(text("2026-10-13T23:00:00+02:00", now: justAfterMidnight), "Yesterday")
        XCTAssertEqual(text("2026-10-12T23:59:00+02:00", now: justAfterMidnight), "2 days ago")
        // New Year's: yesterday, then a dated previous year beyond six days.
        let newYear = try! Date.ISO8601FormatStyle().parse("2027-01-01T08:00:00+01:00")
        XCTAssertEqual(text("2026-12-31T22:00:00+01:00", now: newYear), "Yesterday")
        XCTAssertEqual(text("2026-12-25T12:00:00+01:00", now: newYear), "Dec 25, 2026")
    }

    func testFutureDates() {
        XCTAssertEqual(text("2026-10-14T15:30:59+02:00"), "just now")
        XCTAssertEqual(text("2026-10-14T15:31:01+02:00"), "Oct 14")
        XCTAssertEqual(text("2027-02-01T00:00:00+01:00"), "Feb 1, 2027")
    }

    func testUnparsableInputIsReturnedUnchanged() {
        XCTAssertEqual(text("not a date"), "not a date")
        XCTAssertEqual(text(""), "")
        XCTAssertNil(RelativeCommitDate.date(from: "2026-13-45"))
    }

    func testDateParsesTheRawString() {
        XCTAssertEqual(RelativeCommitDate.date(from: "2026-10-14T15:30:00+02:00"), now)
    }
}
