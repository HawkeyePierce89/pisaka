import XCTest
@testable import PisakaCore

/// Pins the occurrence highlight's textual scans: whole-word and case-sensitive
/// for an identifier, literal for a selected string, and `nil` — never a partial
/// list — when the charged budget runs out.
///
/// The budget cases assert the *work*, not a clock: the ceiling is driven to
/// exhaustion **and** the work the scan really performed (`Work.performed`,
/// booked apart from the charge) stays within what that ceiling paid for. See
/// `EditorConfigGlobTests` for why exhaustion alone is not the property.
final class OccurrenceScanTests: XCTestCase {

    private func ranges(of needle: String, in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        while true {
            let found = text.range(
                of: needle, options: .literal, range: NSRange(location: start, length: text.length - start)
            )
            guard found.location != NSNotFound else { return result }
            result.append(found)
            start = NSMaxRange(found)
        }
    }

    // MARK: - Identifier matches

    func testIdentifierMatchesAreWholeWordOnly() {
        let text = "foo.bar foobar _foo foo_ foo(1) barfoo foo" as NSString
        let matches = OccurrenceScan.identifierMatches(of: "foo", in: text)
        XCTAssertEqual(matches, [
            NSRange(location: 0, length: 3),
            NSRange(location: 25, length: 3),
            NSRange(location: 39, length: 3),
        ])
    }

    func testIdentifierMatchesAreCaseSensitive() {
        let text = "value Value VALUE value" as NSString
        XCTAssertEqual(
            OccurrenceScan.identifierMatches(of: "value", in: text),
            [NSRange(location: 0, length: 5), NSRange(location: 18, length: 5)]
        )
    }

    func testDollarNameIsOneWordInTypeScriptButNotInSwift() {
        let text = "const $x = x + $x; c$x" as NSString
        XCTAssertEqual(
            OccurrenceScan.identifierMatches(of: "$x", in: text, language: .typescript),
            [NSRange(location: 6, length: 2), NSRange(location: 15, length: 2)]
        )
        // `x` inside `$x` and `c$x` is not a whole word in TypeScript…
        XCTAssertEqual(
            OccurrenceScan.identifierMatches(of: "x", in: text, language: .typescript),
            [NSRange(location: 11, length: 1)]
        )
        // …and `$x` is no identifier at all by the language-free rule.
        XCTAssertEqual(OccurrenceScan.identifierMatches(of: "$x", in: text, language: .swift), [])
    }

    func testCreateStoreApiClientSampleFindsItsThreeStarted() {
        let text = """
        export function createStoreApiClient(baseUrl: string) {
          let started = false;
          const startedAt = Date.now();
          return {
            start() {
              if (started) return;
              started = true;
              notStarted.clear();
            },
          };
        }
        """ as NSString
        let matches = OccurrenceScan.identifierMatches(of: "started", in: text, language: .typescript)
        XCTAssertEqual(matches?.count, 3)
        XCTAssertEqual(matches?.map { text.substring(with: $0) }, ["started", "started", "started"])
        XCTAssertEqual(matches, ranges(of: "started", in: text).filter { range in
            IdentifierScanner.identifier(in: text, at: range.location, language: .typescript)?.range == range
        })
    }

    func testANonIdentifierQueryScansNothing() {
        let text = "a b c" as NSString
        XCTAssertEqual(OccurrenceScan.identifierMatches(of: "", in: text), [])
        XCTAssertEqual(OccurrenceScan.identifierMatches(of: "9foo", in: text), [])
        XCTAssertEqual(OccurrenceScan.identifierMatches(of: "a b", in: text), [])
    }

    func testLeadingDigitsTrimLikeTheScanner() {
        // The scanner's trim rule, inherited whole: `123foo` reports `foo`.
        let text = "123foo foo" as NSString
        XCTAssertEqual(
            OccurrenceScan.identifierMatches(of: "foo", in: text),
            [NSRange(location: 3, length: 3), NSRange(location: 7, length: 3)]
        )
    }

    // MARK: - Exact matches

    func testExactMatchesAreLiteralCaseSensitiveAndNonOverlapping() {
        let text = "a.b A.B a.ba.b aaaa" as NSString
        XCTAssertEqual(
            OccurrenceScan.exactMatches(of: "a.b", in: text),
            [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 11, length: 3)]
        )
        XCTAssertEqual(
            OccurrenceScan.exactMatches(of: "aa", in: text),
            [NSRange(location: 15, length: 2), NSRange(location: 17, length: 2)]
        )
        XCTAssertEqual(OccurrenceScan.exactMatches(of: "", in: text), [])
        XCTAssertEqual(OccurrenceScan.exactMatches(of: "longer than the text itself", in: text), [])
    }

    func testExactMatchesStopAtTheLimit() {
        let text = String(repeating: "ab ", count: 10) as NSString
        XCTAssertEqual(OccurrenceScan.exactMatches(of: "ab", in: text, limit: 4)?.count, 4)
    }

    // MARK: - Budget

    func testIdentifierScanReturnsNilWhenTheBudgetRunsOutOnOneLongLine() {
        let ceiling = 10_000
        let text = String(repeating: "x ", count: 50_000) as NSString
        var work = OccurrenceScan.Work(budget: ceiling)
        XCTAssertNil(OccurrenceScan.identifierMatches(of: "x", in: text, language: nil, work: &work))
        XCTAssertLessThanOrEqual(work.budget, 0)
        XCTAssertGreaterThanOrEqual(work.performed, ceiling)
        XCTAssertLessThanOrEqual(work.performed, 2 * ceiling)
    }

    func testExactScanReturnsNilWhenTheBudgetRunsOutWithNoMatchInTheWindow() {
        let ceiling = 10_000
        let text = (String(repeating: "a", count: 100_000) + "needle") as NSString
        var work = OccurrenceScan.Work(budget: ceiling)
        XCTAssertNil(OccurrenceScan.exactMatches(of: "needle", in: text, limit: .max, work: &work))
        XCTAssertLessThanOrEqual(work.budget, 0)
        XCTAssertGreaterThanOrEqual(work.performed, ceiling)
        XCTAssertLessThanOrEqual(work.performed, 2 * ceiling)
    }

    /// A needle repeated inside one long identifier run is the input that would
    /// make the whole-word check quadratic — every hit re-walking the run. The
    /// scan resumes past the run instead, so the work stays linear in the text.
    func testANeedleRepeatedInsideOneRunStaysLinear() {
        let text = String(repeating: "_1", count: 200_000) as NSString
        var work = OccurrenceScan.Work(budget: OccurrenceScan.maximumWorkUnits)
        XCTAssertEqual(OccurrenceScan.identifierMatches(of: "_1", in: text, language: nil, work: &work), [])
        XCTAssertGreaterThan(work.budget, 0)
        XCTAssertLessThanOrEqual(work.performed, 2 * text.length)
    }

    func testAnOrdinaryFileFitsTheProductionCeiling() {
        let text = String(repeating: "let value = other + value;\n", count: 20_000) as NSString
        XCTAssertEqual(OccurrenceScan.identifierMatches(of: "value", in: text)?.count, 40_000)
        XCTAssertEqual(OccurrenceScan.exactMatches(of: "= other", in: text)?.count, 20_000)
    }

    func testTheProductionCeilingIsTheStatedConstant() {
        XCTAssertEqual(OccurrenceScan.maximumWorkUnits, 2_097_152)
        let huge = String(repeating: "x ", count: 1_100_000) as NSString
        XCTAssertNil(OccurrenceScan.identifierMatches(of: "x", in: huge))
    }
}
