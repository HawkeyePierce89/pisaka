import XCTest
@testable import PisakaCore

final class LogFilterDraftTests: XCTestCase {

    // MARK: - Helpers

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        return utcCalendar().date(from: comps)!
    }

    // MARK: - Seeding

    func testInitFromFilterWithNilBoundsDisablesTogglesAndParksOnDefaultDate() {
        let defaultDate = date(year: 2026, month: 1, day: 1)
        let filter = LogFilter()
        let draft = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        XCTAssertFalse(draft.sinceEnabled)
        XCTAssertEqual(draft.since, defaultDate)
        XCTAssertFalse(draft.untilEnabled)
        XCTAssertEqual(draft.until, defaultDate)
        XCTAssertEqual(draft.author, "")
        XCTAssertEqual(draft.path, "")
        XCTAssertEqual(draft.refSelection, .all)
    }

    func testInitFromFilterWithPresentBoundsSeedsVerbatim() {
        let defaultDate = date(year: 2026, month: 1, day: 1)
        let since = date(year: 2026, month: 3, day: 10, hour: 12, minute: 34, second: 56)
        let until = date(year: 2026, month: 3, day: 11, hour: 23, minute: 59, second: 59)
        let filter = LogFilter(
            refSelection: .ref("refs/heads/main"),
            author: "Alice",
            since: since,
            until: until,
            path: "src"
        )
        let draft = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        XCTAssertTrue(draft.sinceEnabled)
        XCTAssertEqual(draft.since, since)
        XCTAssertTrue(draft.untilEnabled)
        XCTAssertEqual(draft.until, until)
        XCTAssertEqual(draft.author, "Alice")
        XCTAssertEqual(draft.path, "src")
        XCTAssertEqual(draft.refSelection, .ref("refs/heads/main"))
    }

    // MARK: - Trimming / blank -> nil

    func testFilterTrimsAuthorAndPath() {
        var draft = LogFilterDraft()
        draft.author = "  Bob  "
        draft.path = "  Sources/foo.swift  "
        let filter = draft.filter(calendar: utcCalendar())
        XCTAssertEqual(filter.author, "Bob")
        XCTAssertEqual(filter.path, "Sources/foo.swift")
    }

    func testFilterBlankAuthorAndPathBecomeNil() {
        var draft = LogFilterDraft()
        draft.author = "   "
        draft.path = ""
        let filter = draft.filter(calendar: utcCalendar())
        XCTAssertNil(filter.author)
        XCTAssertNil(filter.path)
    }

    func testFilterWhitespaceOnlyAuthorAndPathAreNil() {
        var draft = LogFilterDraft(author: "\n\t ", path: " \n ")
        let filter = draft.filter(calendar: utcCalendar())
        XCTAssertNil(filter.author)
        XCTAssertNil(filter.path)
    }

    // MARK: - Day-boundary normalization

    func testSinceNormalizedToStartOfDay() {
        var draft = LogFilterDraft()
        draft.sinceEnabled = true
        draft.since = date(year: 2026, month: 3, day: 10, hour: 15, minute: 30, second: 45)
        let cal = utcCalendar()
        let filter = draft.filter(calendar: cal)
        XCTAssertEqual(filter.since, date(year: 2026, month: 3, day: 10, hour: 0, minute: 0, second: 0))
    }

    func testUntilNormalizedToLastSecondOfDay() {
        var draft = LogFilterDraft()
        draft.untilEnabled = true
        draft.until = date(year: 2026, month: 3, day: 10, hour: 8, minute: 0, second: 0)
        let cal = utcCalendar()
        let filter = draft.filter(calendar: cal)
        XCTAssertEqual(filter.until, date(year: 2026, month: 3, day: 10, hour: 23, minute: 59, second: 59))
    }

    func testDisabledBoundsProduceNilDates() {
        var draft = LogFilterDraft()
        draft.sinceEnabled = false
        draft.since = date(year: 2026, month: 3, day: 10, hour: 12)
        draft.untilEnabled = false
        draft.until = date(year: 2026, month: 3, day: 11, hour: 12)
        let filter = draft.filter(calendar: utcCalendar())
        XCTAssertNil(filter.since)
        XCTAssertNil(filter.until)
    }

    func testUntilNormalizationInclusiveOnDay() {
        // Pick a time in the middle of the day; normalization should land on the
        // last second of *that* day, not next-day midnight.
        var draft = LogFilterDraft()
        draft.untilEnabled = true
        draft.until = date(year: 2026, month: 6, day: 15, hour: 14, minute: 30)
        let cal = utcCalendar()
        let filter = draft.filter(calendar: cal)
        let expected = date(year: 2026, month: 6, day: 15, hour: 23, minute: 59, second: 59)
        XCTAssertEqual(filter.until, expected)
        // Verify the next-day midnight is excluded.
        let nextMidnight = date(year: 2026, month: 6, day: 16, hour: 0, minute: 0, second: 0)
        XCTAssertNotEqual(filter.until, nextMidnight)
    }

    // MARK: - Idempotent round-trip

    func testSeedFilterSeedRoundTripIsIdempotent() {
        let cal = utcCalendar()
        let defaultDate = date(year: 2026, month: 1, day: 1)
        // Use a draft whose dates are mid-day; filter() normalizes them.
        var draft = LogFilterDraft()
        draft.refSelection = .ref("refs/heads/feature")
        draft.author = "Alice"
        draft.path = "src"
        draft.sinceEnabled = true
        draft.since = date(year: 2026, month: 4, day: 5, hour: 10, minute: 20)
        draft.untilEnabled = true
        draft.until = date(year: 2026, month: 4, day: 6, hour: 22, minute: 10)

        let filter = draft.filter(calendar: cal)
        let reseeded = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        let refilter = reseeded.filter(calendar: cal)

        XCTAssertEqual(filter, refilter)
        XCTAssertEqual(reseeded.since, filter.since)
        XCTAssertEqual(reseeded.until, filter.until)
    }

    func testUntilRoundTripPreservesDay() {
        // The inclusive last-second instant is still on the selected day, so
        // seeding it verbatim and re-deriving gives the same bound.
        let cal = utcCalendar()
        let defaultDate = date(year: 2026, month: 1, day: 1)
        let pickedDay = date(year: 2026, month: 5, day: 20, hour: 9, minute: 0)
        var draft = LogFilterDraft()
        draft.untilEnabled = true
        draft.until = pickedDay

        let filter = draft.filter(calendar: cal)
        let reseeded = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        // Reseeded until is the normalized last-second instant, still on May 20.
        let reseededDay = cal.component(.day, from: reseeded.until)
        XCTAssertEqual(reseededDay, 20)
        XCTAssertEqual(filter, reseeded.filter(calendar: cal))
    }

    func testNilBoundsRoundTrip() {
        let cal = utcCalendar()
        let defaultDate = date(year: 2026, month: 1, day: 1)
        let filter = LogFilter(author: "Bob", path: "src")
        let draft = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        XCTAssertFalse(draft.sinceEnabled)
        XCTAssertFalse(draft.untilEnabled)
        let reassembled = draft.filter(calendar: cal)
        XCTAssertEqual(reassembled, filter)
    }

    // MARK: - Verbatim ref preservation

    func testVerbatimRefPreservedDespiteEmptyReferences() {
        var draft = LogFilterDraft()
        draft.refSelection = .ref("refs/heads/main")
        let cal = utcCalendar()
        let filter = draft.filter(calendar: cal)
        // filter still emits the named ref even though references is empty.
        XCTAssertEqual(filter.refSelection, .ref("refs/heads/main"))
        // Display resolves to "All" when the ref is unknown.
        XCTAssertEqual(draft.displayRefTag(amongKnown: []), LogFilterDraft.allRefsTag)
        // With the ref known, it displays the ref itself.
        XCTAssertEqual(draft.displayRefTag(amongKnown: ["refs/heads/main"]), "refs/heads/main")
    }

    func testAllRefDisplaysAsAllTagRegardlessOfReferences() {
        let draft = LogFilterDraft(refSelection: .all)
        XCTAssertEqual(draft.displayRefTag(amongKnown: []), LogFilterDraft.allRefsTag)
        XCTAssertEqual(draft.displayRefTag(amongKnown: ["refs/heads/main"]), LogFilterDraft.allRefsTag)
    }

    func testUnknownRefDisplaysAsAllTagButFilterPreservesIt() {
        var draft = LogFilterDraft()
        draft.refSelection = .ref("refs/heads/gone")
        XCTAssertEqual(draft.displayRefTag(amongKnown: ["refs/heads/main"]), LogFilterDraft.allRefsTag)
        XCTAssertEqual(draft.filter(calendar: utcCalendar()).refSelection, .ref("refs/heads/gone"))
    }

    // MARK: - selectRef

    func testSelectRefWithEmptyTagSelectsAll() {
        var draft = LogFilterDraft(refSelection: .ref("refs/heads/main"))
        draft.selectRef(tag: "")
        XCTAssertEqual(draft.refSelection, .all)
        draft.selectRef(tag: LogFilterDraft.allRefsTag)
        XCTAssertEqual(draft.refSelection, .all)
    }

    func testSelectRefWithTagSelectsRef() {
        var draft = LogFilterDraft()
        draft.selectRef(tag: "refs/heads/feature")
        XCTAssertEqual(draft.refSelection, .ref("refs/heads/feature"))
    }

    func testSelectRefRoundTripWithDisplay() {
        var draft = LogFilterDraft()
        draft.selectRef(tag: "refs/heads/main")
        XCTAssertEqual(draft.displayRefTag(amongKnown: ["refs/heads/main"]), "refs/heads/main")
        draft.selectRef(tag: LogFilterDraft.allRefsTag)
        XCTAssertEqual(draft.refSelection, .all)
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = LogFilterDraft(
            refSelection: .ref("refs/heads/main"),
            author: "Alice",
            path: "src",
            sinceEnabled: true,
            since: date(year: 2026, month: 1, day: 1),
            untilEnabled: false,
            until: date(year: 2026, month: 1, day: 2)
        )
        var b = a
        XCTAssertEqual(a, b)
        b.author = "Bob"
        XCTAssertNotEqual(a, b)
        b = a
        b.sinceEnabled = false
        XCTAssertNotEqual(a, b)
        b = a
        b.refSelection = .all
        XCTAssertNotEqual(a, b)
    }

    func testEquatablePathAndUntilDimensions() {
        let base = LogFilterDraft(author: "A", path: "src", sinceEnabled: true, since: date(year: 2026, month: 1, day: 1))
        var mutated = base
        mutated.path = "other"
        XCTAssertNotEqual(base, mutated)
        mutated = base
        mutated.untilEnabled = true
        mutated.until = date(year: 2026, month: 1, day: 5)
        XCTAssertNotEqual(base, mutated)
    }
}
