import XCTest
@testable import PisakaCore

/// Tests for the one shared search-query history — the recording rule, the cap,
/// the read-side normalization, the whole-value persistence failure mode and the
/// menu row's text. Every decision the two macOS search surfaces render lives
/// here, so this suite is the whole gate for them.
final class SearchQueryHistoryTests: XCTestCase {

    // MARK: - The recording rule

    func testAFreshHistoryIsEmpty() {
        let history = SearchQueryHistory()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.entries, [])
    }

    func testRecordingKeepsNewestFirst() {
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "one"))
        history.record(SearchQuery(pattern: "two"))
        history.record(SearchQuery(pattern: "three"))
        XCTAssertEqual(history.entries.map(\.pattern), ["three", "two", "one"])
        XCTAssertFalse(history.isEmpty)
    }

    func testAnEmptyPatternIsRefused() {
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: ""))
        XCTAssertTrue(history.isEmpty)
    }

    func testAWhitespaceOnlyPatternIsRefused() {
        var history = SearchQueryHistory()
        // Tabs and spaces together: the refusal is on the *trimmed* value, not
        // on `isEmpty`.
        history.record(SearchQuery(pattern: " \t  \t "))
        history.record(SearchQuery(pattern: "\n"))
        XCTAssertTrue(history.isEmpty)
    }

    func testAPatternWithSurroundingSpaceIsRecordedUntrimmed() {
        // Blankness is what is refused; a pattern that *contains* real text is
        // stored exactly as typed, spaces and all — they are part of the search.
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "  foo  "))
        XCTAssertEqual(history.entries.map(\.pattern), ["  foo  "])
    }

    func testRecordingAHeldPatternPromotesItAndTheNewerFlagsWin() {
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "foo", isRegex: true, caseSensitive: true))
        history.record(SearchQuery(pattern: "bar"))
        history.record(SearchQuery(pattern: "foo", wholeWord: true))

        XCTAssertEqual(history.entries.map(\.pattern), ["foo", "bar"])
        XCTAssertEqual(
            history.entries.first,
            SearchQuery(pattern: "foo", isRegex: false, caseSensitive: false, wholeWord: true)
        )
    }

    func testADifferentlyCasedPatternIsADifferentEntry() {
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "foo"))
        history.record(SearchQuery(pattern: "Foo"))
        XCTAssertEqual(history.entries.map(\.pattern), ["Foo", "foo"])
    }

    func testRecordingTheFrontEntryUnchangedLeavesTheValueEqual() {
        // The no-op the store's writer guards on: same pattern, same flags,
        // already at the front.
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "foo", caseSensitive: true))
        history.record(SearchQuery(pattern: "bar"))
        let before = history

        var after = before
        after.record(SearchQuery(pattern: "bar"))
        XCTAssertEqual(after, before)
    }

    func testTheCapDropsTheOldest() {
        var history = SearchQueryHistory()
        for index in 0..<(SearchQueryHistory.capacity + 5) {
            history.record(SearchQuery(pattern: "q\(index)"))
        }
        XCTAssertEqual(SearchQueryHistory.capacity, 20)
        XCTAssertEqual(history.entries.count, SearchQueryHistory.capacity)
        XCTAssertEqual(history.entries.first?.pattern, "q24")
        XCTAssertEqual(history.entries.last?.pattern, "q5")
    }

    func testClearEmptiesTheHistory() {
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "foo"))
        history.clear()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history, SearchQueryHistory())
    }

    // MARK: - Read-side normalization

    func testInitFromEntriesNormalizesADirtyList() {
        let dirty =
            [SearchQuery(pattern: "newest", wholeWord: true)]
            + [SearchQuery(pattern: "   ")]
            + [SearchQuery(pattern: "newest", isRegex: true)]
            + (0..<(SearchQueryHistory.capacity + 5)).map { SearchQuery(pattern: "q\($0)") }

        let history = SearchQueryHistory(entries: dirty)

        XCTAssertEqual(history.entries.count, SearchQueryHistory.capacity)
        // Blank dropped, the duplicate collapsed to the newest-first occurrence
        // with its own flags, and the tail truncated.
        XCTAssertEqual(history.entries.first, SearchQuery(pattern: "newest", wholeWord: true))
        XCTAssertEqual(history.entries.map(\.pattern).filter { $0 == "newest" }.count, 1)
        XCTAssertFalse(history.entries.contains { $0.pattern == "   " })
    }

    func testInitFromEntriesRoundTripsAnAlreadyValidList() {
        var recorded = SearchQueryHistory()
        recorded.record(SearchQuery(pattern: "one"))
        recorded.record(SearchQuery(pattern: "two", caseSensitive: true))
        XCTAssertEqual(SearchQueryHistory(entries: recorded.entries), recorded)
    }

    // MARK: - Persistence

    func testPersistedDataIsNilWhileEmpty() {
        XCTAssertNil(SearchQueryHistory().persistedData)
    }

    func testPersistedDataRoundTrips() throws {
        var history = SearchQueryHistory()
        history.record(SearchQuery(pattern: "plain"))
        history.record(SearchQuery(pattern: "flagged", isRegex: true, caseSensitive: true, wholeWord: true))

        let data = try XCTUnwrap(history.persistedData)
        XCTAssertEqual(SearchQueryHistory(persistedData: data), history)
    }

    func testTheCapSurvivesTheRoundTrip() throws {
        var history = SearchQueryHistory()
        for index in 0..<(SearchQueryHistory.capacity + 5) {
            history.record(SearchQuery(pattern: "q\(index)"))
        }
        let data = try XCTUnwrap(history.persistedData)
        XCTAssertEqual(SearchQueryHistory(persistedData: data).entries, history.entries)
    }

    func testAbsentDataReadsAsEmpty() {
        XCTAssertTrue(SearchQueryHistory(persistedData: nil).isEmpty)
    }

    func testNonJSONDataReadsAsEmpty() {
        XCTAssertTrue(SearchQueryHistory(persistedData: Data([0x00, 0x01, 0xFF])).isEmpty)
    }

    func testAJSONObjectInsteadOfAnArrayReadsAsEmpty() {
        let data = Data(#"{"pattern":"foo","isRegex":false,"caseSensitive":false,"wholeWord":false}"#.utf8)
        XCTAssertTrue(SearchQueryHistory(persistedData: data).isEmpty)
    }

    func testAnElementMissingAKeyDropsTheWholeList() {
        // The whole point of the whole-value failure mode: the *readable*
        // neighbour is discarded too, rather than leaving a list with an
        // invisible hole in it.
        let data = Data("""
        [{"pattern":"good","isRegex":false,"caseSensitive":false,"wholeWord":false},
         {"isRegex":false,"caseSensitive":false,"wholeWord":false}]
        """.utf8)
        XCTAssertTrue(SearchQueryHistory(persistedData: data).isEmpty)
    }

    func testAnElementWithAMistypedKeyDropsTheWholeList() {
        let data = Data("""
        [{"pattern":"good","isRegex":"yes","caseSensitive":false,"wholeWord":false}]
        """.utf8)
        XCTAssertTrue(SearchQueryHistory(persistedData: data).isEmpty)
    }

    func testDecodingReplaysTheRecordingRule() {
        // A list from anywhere — an older build, a hand-edited domain — reads
        // back as one this type could have produced.
        let blank = #"{"pattern":"  ","isRegex":false,"caseSensitive":false,"wholeWord":false}"#
        let first = #"{"pattern":"dup","isRegex":false,"caseSensitive":false,"wholeWord":true}"#
        let second = #"{"pattern":"dup","isRegex":true,"caseSensitive":false,"wholeWord":false}"#
        let data = Data("[\(first),\(blank),\(second)]".utf8)

        let history = SearchQueryHistory(persistedData: data)
        XCTAssertEqual(history.entries, [SearchQuery(pattern: "dup", wholeWord: true)])
    }

    // MARK: - The menu row's text

    func testMenuLabelOfAShortPatternIsThePatternAlone() {
        XCTAssertEqual(SearchQueryHistory.menuLabel(for: SearchQuery(pattern: "foo")), "foo")
    }

    func testMenuLabelMiddleTruncatesALongPattern() {
        let pattern = String(repeating: "a", count: 100) + String(repeating: "b", count: 100)
        let label = SearchQueryHistory.menuLabel(for: SearchQuery(pattern: pattern))

        XCTAssertEqual(label.count, 60)
        XCTAssertEqual(label.filter { $0 == "…" }.count, 1)
        XCTAssertTrue(label.hasPrefix(String(repeating: "a", count: 30)))
        XCTAssertTrue(label.hasSuffix(String(repeating: "b", count: 29)))
    }

    func testMenuLabelHonoursACustomMaxPatternLength() {
        let label = SearchQueryHistory.menuLabel(
            for: SearchQuery(pattern: "abcdefghij"),
            maxPatternLength: 5
        )
        // The `…` is counted against the budget, and the odd character left over
        // goes to the head — the pattern's start is what identifies it.
        XCTAssertEqual(label, "ab…ij")
        XCTAssertEqual(label.count, 5)
    }

    func testMenuLabelLeavesAPatternOfExactlyTheLimitAlone() {
        let pattern = String(repeating: "x", count: 60)
        XCTAssertEqual(SearchQueryHistory.menuLabel(for: SearchQuery(pattern: pattern)), pattern)
    }

    func testMenuLabelFlagSuffixes() {
        func label(_ query: SearchQuery) -> String { SearchQueryHistory.menuLabel(for: query) }

        XCTAssertEqual(label(SearchQuery(pattern: "q")), "q")
        XCTAssertEqual(label(SearchQuery(pattern: "q", caseSensitive: true)), "q Aa")
        XCTAssertEqual(label(SearchQuery(pattern: "q", wholeWord: true)), "q ab")
        XCTAssertEqual(label(SearchQuery(pattern: "q", isRegex: true)), "q .*")
        XCTAssertEqual(label(SearchQuery(pattern: "q", caseSensitive: true, wholeWord: true)), "q Aa ab")
        XCTAssertEqual(label(SearchQuery(pattern: "q", isRegex: true, caseSensitive: true)), "q Aa .*")
        XCTAssertEqual(label(SearchQuery(pattern: "q", isRegex: true, wholeWord: true)), "q ab .*")
        XCTAssertEqual(
            label(SearchQuery(pattern: "q", isRegex: true, caseSensitive: true, wholeWord: true)),
            "q Aa ab .*"
        )
    }

    /// The degenerate budgets, which the guards in `truncatedMiddle` are the whole
    /// of: `maxPatternLength` is a parameter a caller picks, and the promise that
    /// the pattern is never longer than asked for has to hold at 0, 1 and 2 too —
    /// 2 being the one budget that buys a head character and the ellipsis and no
    /// tail at all.
    func testMenuLabelHonoursDegenerateBudgets() {
        let query = SearchQuery(pattern: "abcdef")

        XCTAssertEqual(SearchQueryHistory.menuLabel(for: query, maxPatternLength: 0), "")
        XCTAssertEqual(SearchQueryHistory.menuLabel(for: query, maxPatternLength: 1), "…")
        XCTAssertEqual(SearchQueryHistory.menuLabel(for: query, maxPatternLength: 2), "a…")

        for budget in 0...6 {
            let label = SearchQueryHistory.menuLabel(for: query, maxPatternLength: budget)
            XCTAssertLessThanOrEqual(label.count, budget, "budget \(budget)")
        }
    }

    /// The flag suffix is not the pattern, so it is appended even when the budget
    /// leaves no room for the pattern itself — a row that says only "…" still says
    /// which toggles it was searched under.
    func testMenuLabelKeepsTheFlagsUnderADegenerateBudget() {
        let label = SearchQueryHistory.menuLabel(
            for: SearchQuery(pattern: "abcdef", isRegex: true, caseSensitive: true, wholeWord: true),
            maxPatternLength: 1
        )
        XCTAssertEqual(label, "… Aa ab .*")
    }

    func testMenuLabelTruncatesThePatternOnlyAndKeepsTheFlags() {
        let pattern = String(repeating: "z", count: 200)
        let label = SearchQueryHistory.menuLabel(
            for: SearchQuery(pattern: pattern, isRegex: true, caseSensitive: true, wholeWord: true)
        )
        XCTAssertEqual(label.count, 60 + " Aa ab .*".count)
        XCTAssertTrue(label.hasSuffix(" Aa ab .*"))
    }
}
