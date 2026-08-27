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

    // MARK: - Seeding an existing draft

    func testSeedFromFilterWithAbsentSinceClearsFlagButKeepsTheDayShown() {
        let chosen = date(year: 2026, month: 3, day: 10, hour: 0)
        var draft = LogFilterDraft()
        draft.sinceEnabled = true
        draft.since = chosen

        draft.seed(from: LogFilter())

        XCTAssertFalse(draft.sinceEnabled)
        XCTAssertEqual(draft.since, chosen)
    }

    func testSeedFromFilterWithAbsentUntilClearsFlagButKeepsTheDayShown() {
        let chosen = date(year: 2026, month: 3, day: 11, hour: 23, minute: 59, second: 59)
        var draft = LogFilterDraft()
        draft.untilEnabled = true
        draft.until = chosen

        draft.seed(from: LogFilter())

        XCTAssertFalse(draft.untilEnabled)
        XCTAssertEqual(draft.until, chosen)
    }

    func testSeedFromFilterWithPresentBoundsOverwritesFlagsAndDatesVerbatim() {
        let since = date(year: 2026, month: 4, day: 1, hour: 0)
        let until = date(year: 2026, month: 4, day: 2, hour: 23, minute: 59, second: 59)
        var draft = LogFilterDraft()
        draft.since = date(year: 2020, month: 1, day: 1)
        draft.until = date(year: 2020, month: 1, day: 2)

        draft.seed(from: LogFilter(since: since, until: until))

        XCTAssertTrue(draft.sinceEnabled)
        XCTAssertEqual(draft.since, since)
        XCTAssertTrue(draft.untilEnabled)
        XCTAssertEqual(draft.until, until)
    }

    func testSeedOverwritesRefAuthorAndPathVerbatim() {
        var draft = LogFilterDraft(refSelection: .ref("refs/heads/old"), author: "Alice", path: "src")

        draft.seed(from: LogFilter(refSelection: .ref("refs/heads/gone"), author: "Bob", path: "docs"))

        // The unknown ref is carried, never re-resolved.
        XCTAssertEqual(draft.refSelection, .ref("refs/heads/gone"))
        XCTAssertEqual(draft.displayRefTag(amongKnown: ["refs/heads/main"]), LogFilterDraft.allRefsTag)
        XCTAssertEqual(draft.author, "Bob")
        XCTAssertEqual(draft.path, "docs")

        draft.seed(from: LogFilter())

        XCTAssertEqual(draft.refSelection, .all)
        XCTAssertEqual(draft.author, "")
        XCTAssertEqual(draft.path, "")
    }

    func testUntickAndRetickJourneyKeepsTheChosenDay() {
        let cal = utcCalendar()
        var draft = LogFilterDraft()

        // The user picks a day and the resulting filter is published back.
        draft.sinceEnabled = true
        draft.since = date(year: 2026, month: 5, day: 20, hour: 9, minute: 0)
        let chosen = draft.filter(calendar: cal)
        draft.seed(from: chosen)

        // The user unticks Since; the model publishes a filter without the bound.
        draft.sinceEnabled = false
        let cleared = draft.filter(calendar: cal)
        XCTAssertNil(cleared.since)
        draft.seed(from: cleared)

        // Re-ticking re-derives the same day boundary, not today's.
        draft.sinceEnabled = true
        XCTAssertEqual(draft.filter(calendar: cal).since, chosen.since)
    }

    /// The same journey for `until`, which is the asymmetric bound: its seeded value
    /// is the *derived* last-second-of-day instant, so the day survives a re-tick
    /// only while `endOfDay` stays idempotent across a re-seed. Two cycles, so a
    /// per-cycle drift of one day is visible rather than only the first hop.
    func testUntickAndRetickJourneyKeepsTheChosenUntilDay() {
        let cal = utcCalendar()
        var draft = LogFilterDraft()

        draft.untilEnabled = true
        draft.until = date(year: 2026, month: 5, day: 20, hour: 9, minute: 0)
        let chosen = draft.filter(calendar: cal)
        XCTAssertEqual(chosen.until, date(year: 2026, month: 5, day: 20, hour: 23, minute: 59, second: 59))
        draft.seed(from: chosen)

        for _ in 0..<2 {
            // Untick: the model publishes a filter without the bound.
            draft.untilEnabled = false
            let cleared = draft.filter(calendar: cal)
            XCTAssertNil(cleared.until)
            draft.seed(from: cleared)

            // Re-tick: the same day boundary comes back, not today's.
            draft.untilEnabled = true
            let reticked = draft.filter(calendar: cal)
            XCTAssertEqual(reticked.until, chosen.until)
            draft.seed(from: reticked)
        }
    }

    /// The two seeding forms are one rule: parking both dates on `defaultDate` and
    /// then seeding is what the from-scratch `init` does. Asserted against a
    /// hand-written expectation rather than against `init` itself, so it stays a
    /// real check of *what* that rule produces (in particular that the flags come
    /// from the filter, not from the parked draft) instead of restating the
    /// delegation.
    func testSeedOntoAParkedDraftProducesTheFromScratchResult() {
        let defaultDate = date(year: 2026, month: 1, day: 1)
        let since = date(year: 2026, month: 2, day: 2)
        let filter = LogFilter(
            refSelection: .ref("refs/heads/main"),
            author: "Alice",
            since: since,
            path: "src"
        )
        // Park exactly as `init(filter:defaultDate:)` does — both flags off.
        var seeded = LogFilterDraft(since: defaultDate, until: defaultDate)
        seeded.seed(from: filter)

        XCTAssertEqual(seeded.refSelection, .ref("refs/heads/main"))
        XCTAssertEqual(seeded.author, "Alice")
        XCTAssertEqual(seeded.path, "src")
        XCTAssertTrue(seeded.sinceEnabled)
        XCTAssertEqual(seeded.since, since)
        // `until` is absent, and a parked draft has no chosen day — so it keeps the
        // parked one, which is what the from-scratch form promises.
        XCTAssertFalse(seeded.untilEnabled)
        XCTAssertEqual(seeded.until, defaultDate)
        XCTAssertEqual(seeded, LogFilterDraft(filter: filter, defaultDate: defaultDate))
    }

    /// The combination the bar actually produces: one bound stated, the other
    /// unticked but still showing a day the user chose earlier. The two dates are
    /// deliberately distinct, so an implementation that coupled the branches (writing
    /// the absent bound from the present one, or re-parking on "now") fails here.
    func testSeedWithOnePresentBoundKeepsTheOtherBoundsRememberedDay() {
        let remembered = date(year: 2026, month: 6, day: 15, hour: 23, minute: 59, second: 59)
        let incomingSince = date(year: 2026, month: 7, day: 1)
        var draft = LogFilterDraft()
        draft.untilEnabled = true
        draft.until = remembered
        draft.since = date(year: 2020, month: 1, day: 1)

        draft.seed(from: LogFilter(since: incomingSince))

        XCTAssertTrue(draft.sinceEnabled)
        XCTAssertEqual(draft.since, incomingSince)
        XCTAssertFalse(draft.untilEnabled)
        XCTAssertEqual(draft.until, remembered)
    }

    /// The mirror image, so neither bound is protected only by the other's branch.
    func testSeedWithOnlyUntilPresentKeepsTheRememberedSinceDay() {
        let remembered = date(year: 2026, month: 6, day: 15)
        let incomingUntil = date(year: 2026, month: 7, day: 2, hour: 23, minute: 59, second: 59)
        var draft = LogFilterDraft()
        draft.sinceEnabled = true
        draft.since = remembered
        draft.until = date(year: 2020, month: 1, day: 2)

        draft.seed(from: LogFilter(until: incomingUntil))

        XCTAssertFalse(draft.sinceEnabled)
        XCTAssertEqual(draft.since, remembered)
        XCTAssertTrue(draft.untilEnabled)
        XCTAssertEqual(draft.until, incomingUntil)
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

    func testUntilRoundTripPreservesDayAcrossAMidnightDSTJump() {
        // Every other date test runs on a UTC calendar, where a day always starts
        // at midnight; production calls `filter()` with `Calendar.current`. In a
        // zone whose DST jump is at midnight the day after the jump begins at
        // 01:00, so a naive `startOfDay + 1 day - 1s` lands on the *next* day —
        // and because `seed(from:)` writes the derived bound back into the draft,
        // the picker would walk a day forward on every apply.
        var cal = Calendar(identifier: .gregorian)
        guard let santiago = TimeZone(identifier: "America/Santiago") else {
            XCTFail("America/Santiago must exist in the platform time-zone database")
            return
        }
        cal.timeZone = santiago
        let defaultDate = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        // 2026-09-06 is the spring-forward day: 23:59:59 on 09-05 is followed by
        // 01:00:00 on 09-06, so 09-06 has no midnight.
        let pickedDay = cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        var draft = LogFilterDraft()
        draft.untilEnabled = true
        draft.until = pickedDay

        let filter = draft.filter(calendar: cal)
        let reseeded = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        XCTAssertTrue(
            cal.isDate(reseeded.until, inSameDayAs: pickedDay),
            "the inclusive bound must stay on the chosen day, got \(reseeded.until)"
        )
        XCTAssertEqual(filter, reseeded.filter(calendar: cal))

        // And a second cycle does not drift either — the round-trip is a fixed
        // point, not merely one step of a walk.
        let refilter = reseeded.filter(calendar: cal)
        let twice = LogFilterDraft(filter: refilter, defaultDate: defaultDate)
        XCTAssertEqual(twice.until, reseeded.until)
    }

    func testSinceRoundTripPreservesDayAcrossAMidnightDSTJump() {
        var cal = Calendar(identifier: .gregorian)
        guard let santiago = TimeZone(identifier: "America/Santiago") else {
            XCTFail("America/Santiago must exist in the platform time-zone database")
            return
        }
        cal.timeZone = santiago
        let defaultDate = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let pickedDay = cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        var draft = LogFilterDraft()
        draft.sinceEnabled = true
        draft.since = pickedDay

        let filter = draft.filter(calendar: cal)
        let reseeded = LogFilterDraft(filter: filter, defaultDate: defaultDate)
        XCTAssertTrue(cal.isDate(reseeded.since, inSameDayAs: pickedDay))
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
